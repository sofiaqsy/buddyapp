import SwiftUI
import MapKit

struct TripDetailView: View {
    let route: Route
    var match: APIMatch? = nil
    var journey: APIJourney? = nil
    var unreadCount: Int = 0
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
    /// Carga progresiva: mostramos lotes de 10 (rail + mapa). Al deslizar el rail
    /// hasta el final se revelan los siguientes 10 y aparecen como markers.
    @State private var visibleCount = 10
    @State private var orderedIds: [UUID] = []   // orden congelado de la sesión

    init(route: Route, match: APIMatch? = nil, journey: APIJourney? = nil, unreadCount: Int = 0) {
        self.route = route
        self.match = match
        self.journey = journey
        self.unreadCount = unreadCount
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
        let destId = journey?.destinationId ?? journey?.destination?.id
        if let destId,
           let ctx = try? await APIClient.shared.fetchDestinationContext(id: destId) {
            await MainActor.run { buddyCount = ctx.buddies }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { fitMap() }

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

                Divider()

                Button(role: .destructive) {
                    showCancelConfirm = true
                } label: {
                    Label("Cancelar trip", systemImage: "xmark.circle")
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

    private func openInGoogleMaps() {
        guard let p = navigationTarget else { return }
        let url = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(p.latitude),\(p.longitude)&travelmode=driving")!
        UIApplication.shared.open(url)
    }

    private func openInWaze() {
        guard let p = navigationTarget else { return }
        let url = URL(string: "https://waze.com/ul?ll=\(p.latitude),\(p.longitude)&navigate=yes")!
        UIApplication.shared.open(url)
    }

    private func openInAppleMaps() {
        guard let p = navigationTarget else { return }
        let name = p.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? p.name
        let url = URL(string: "https://maps.apple.com/?daddr=\(p.latitude),\(p.longitude)&q=\(name)")!
        UIApplication.shared.open(url)
    }

    // MARK: – Bottom panel

    @ViewBuilder
    private func bottomSection(geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
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
                HStack(alignment: .firstTextBaseline) {
                    Text("Recomendado por la comunidad")
                        .font(BT.title2)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(livePlaces.count) recomendaciones")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.teal)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }

            if let place = selectedPlace {
                placeDetail(place)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: selectedPlace?.id)
            } else {
                cardScroll
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: selectedPlace?.id)
            }
        }
        // Glass más alto: el contenido (top-aligned) sube sobre la tab bar y el
        // glass sobrante queda detrás de ella → panel flush, sin hueco de mapa.
        .frame(width: geo.size.width, height: sheetHeight + bottomClearance, alignment: .top)
        .glassPanel()
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
                        PlacePhotoCard(place: place, index: i,
                                       isFavorite: isFav(place),
                                       onToggleFavorite: {
                                           if let jid = journey?.id {
                                               routeStore.toggleFavorite(placeId: place.id, journeyId: jid)
                                           }
                                       })
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

    // MARK: – Place detail

    private func placeDetail(_ place: Place) -> some View {
        let palettes: [[Color]] = [
            [Color(hex: "4A2820"), Color(hex: "6E3B2D")],
            [Color(hex: "3D2B1A"), Color(hex: "6B4226")],
            [Color(hex: "4A3D35"), Color(hex: "7A6558")],
            [Color(hex: "5C3E1A"), Color(hex: "8B6428")],
        ]
        let idx = abs(place.name.hashValue) % palettes.count

        return HStack(spacing: 0) {
            ZStack {
                CachedImage(urlString: place.coverUrl) { img in
                    img.resizable().scaledToFill()
                        .frame(width: 110)
                        .clipped()
                } placeholder: {
                    LinearGradient(colors: palettes[idx], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Text(place.stickerEmoji).font(.system(size: 44)) }
                }
            }
            .frame(width: 110)
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(place.name).font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button {
                        if let jid = journey?.id { routeStore.toggleFavorite(placeId: place.id, journeyId: jid) }
                    } label: {
                        Image(systemName: isFav(place) ? "heart.fill" : "heart")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isFav(place) ? Color.errorRed : Color.ink.opacity(0.45))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                            .symbolEffect(.bounce, value: isFav(place))
                    }
                    .buttonStyle(.plain)
                    // Cómo llegar — abre el lugar en Google Maps / Waze / Apple Maps
                    Button {
                        Haptic.light()
                        navigationTarget = place
                    } label: {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.brand)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cómo llegar a \(place.name)")
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedPlace = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(7)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                Text(place.description).font(.system(size: 13)).foregroundStyle(.secondary)
                Divider()
                if place.isCollected {
                    Label("recuerdo desbloqueado", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.teal)
                } else {
                    Label("aquí desbloqueas un recuerdo", systemImage: "sparkles")
                        .font(.system(size: 13)).foregroundStyle(Color.sand)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: contentHeight - 20)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .frame(height: contentHeight, alignment: .top)
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

    private var glyph: String { place.category.symbol }

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
    var isFavorite: Bool = false
    var onToggleFavorite: () -> Void = {}

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

                // Favorito — círculo blanco siempre legible sobre cualquier foto
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isFavorite ? Color.errorRed : Color.ink.opacity(0.45))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white))
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .symbolEffect(.bounce, value: isFavorite)
                }
                .buttonStyle(.plain)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
