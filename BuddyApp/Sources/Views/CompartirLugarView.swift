import SwiftUI
import CoreLocation
import MapKit

// MARK: - Fase 2 de "Buddy Community Places": el CTA en Tu Trip para que un
// buddy aprobado documente un lugar suelto, sin que eso toque su trip
// personal — reutiliza createJourney(attachToTrip: false) y el mismo editor
// Memoir del flujo normal. Deliberadamente discreta: si el uso confirma la
// idea, se le da más protagonismo en una segunda versión.

// MARK: - Card

struct CompartirLugarCard: View {
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("¿ERES BUDDY?")
                .font(BT.eyebrow)
                .tracking(2)
                .foregroundStyle(Color.inkMuted)

            HStack(spacing: Spacing.sm) {
                Text("🌍").font(.system(size: 22))
                Text("Compartir un lugar")
                    .font(BT.headline)
                    .foregroundStyle(Color.ink)
            }

            Text("Ayuda a futuros viajeros compartiendo fotos\nde un lugar que conoces.")
                .font(BT.footnote)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptic.medium()
                onTap()
            } label: {
                Text("Compartir")
                    .font(BT.footnoteBold)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 10)
                    .background(Color.ink)
                    .foregroundStyle(Color.inkInverse)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
    }
}

// MARK: - Sheet: "¿Dónde estás ahora?"

struct CompartirLugarSheet: View {
    /// Se llama cuando el journey ya existe en el backend (creado o reutilizado)
    /// — el llamador decide qué hacer (típicamente: abrir el editor Memoir).
    let onCreated: (APIJourney) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .choose
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    // Spots curados cercanos (paso "Lugar actual")
    @State private var nearbySpots: [APINearbySpot] = []
    @State private var currentCoords: (lat: Double, lng: Double)?
    /// Dónde nace el mapa: se fija UNA vez al tocar la opción. Leer el GPS en
    /// el body re-renderizaba el sheet en cada fix (cada 2–4 s) y reconstruía
    /// el mapa.
    @State private var mapStart: (lat: Double, lng: Double)?
    @State private var proposedName = ""
    @State private var categories: [APISpotCategory] = []
    @State private var selectedCategoryId: String?
    @State private var isPrefetching = false
    @State private var didPrefetch = false

    enum Step { case choose, map, propose }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .choose:  chooseStep
                case .map:     mapStep
                case .propose: proposePlaceStep
                }
            }
            .navigationTitle("Compartir un lugar")
            .navigationBarTitleDisplayMode(.inline)
            .task { await prefetchNearby() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    // MARK: – Paso 1: elegir origen del lugar

    @ViewBuilder
    private var chooseStep: some View {
        VStack(spacing: Spacing.md) {
            Text("¿DÓNDE ESTÁS AHORA?")
                .font(BT.eyebrow)
                .tracking(2)
                .foregroundStyle(Color.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.lg)

            // Los locales cercanos se listan aquí mismo. Si el botón ya dice el
            // nombre, tocarlo ES la elección — una segunda pantalla preguntando
            // "¿en cuál estás?" repetiría la pregunta que este botón responde.
            if let current = nearbySpots.first {
                Button { Haptic.medium(); submit(spotId: current.id) } label: {
                    optionRow(
                        icon: "location.fill",
                        title: "\(current.name) (Lugar actual)",
                        subtitle: current.isPendingApproval ? "\(current.distanceLabel) · por revisar" : current.distanceLabel,
                        isLoading: isSubmitting
                    )
                }
                .buttonStyle(.pressable)
                .disabled(isSubmitting)

                // Los demás dentro del radio: el GPS puede errar por unos metros
                // y dos locales caben en ese margen.
                ForEach(nearbySpots.dropFirst().prefix(4)) { spot in
                    Button { Haptic.medium(); submit(spotId: spot.id) } label: {
                        optionRow(
                            icon: "mappin.circle.fill",
                            title: spot.name,
                            subtitle: spot.isPendingApproval ? "\(spot.distanceLabel) · por revisar" : spot.distanceLabel,
                            isLoading: false
                        )
                    }
                    .buttonStyle(.pressable)
                    .disabled(isSubmitting)
                }
            }

            // Siempre presente, haya o no lista: el buddy puede estar en un
            // local que el catálogo todavía no conoce, y buscarlo por texto no
            // sirve — si no está aquí, tampoco está en OpenStreetMap.
            Button { useCurrentLocation() } label: {
                optionRow(
                    icon: "plus.circle.fill",
                    title: "Registrar lugar de la ubicación actual",
                    subtitle: nearbySpots.isEmpty
                        ? (isPrefetching ? "buscando…" : "nombra dónde estás")
                        : "ninguno de estos es",
                    isLoading: false
                )
            }
            .buttonStyle(.pressable)
            .disabled(isSubmitting || isPrefetching)

            Button {
                mapStart = currentCoords ?? LocationService.current?.userLocation.map {
                    ($0.coordinate.latitude, $0.coordinate.longitude)
                }
                dlog("📍 [CompartirLugarSheet] Buscar en el mapa tocado — inicio=\(mapStart.map { "(\($0.lat),\($0.lng))" } ?? "sin ubicación")")
                step = .map
            } label: {
                optionRow(icon: "map", title: "Buscar en el mapa", subtitle: "elige un punto o un lugar existente", isLoading: false)
            }
            .buttonStyle(.pressable)
            .disabled(isSubmitting)

            if let errorMessage {
                Text(errorMessage)
                    .font(BT.caption1)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.edge)
    }

    private func optionRow(icon: String, title: String, subtitle: String?, isLoading: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.brand)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BT.headline).foregroundStyle(Color.ink)
                if let subtitle {
                    Text(subtitle).font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
            }
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.8)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .padding(Spacing.md)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
    }

    /// Consulta el catálogo al abrir el sheet, no al tocar un botón: los locales
    /// cercanos SON las opciones de la primera pantalla, así que tienen que
    /// estar antes de pintarla. En paralelo trae las categorías, que hacen falta
    /// en el único camino que sigue: nombrar un lugar que no existe.
    private func prefetchNearby() async {
        guard !didPrefetch, let loc = LocationService.current?.userLocation else { return }
        didPrefetch = true
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        await MainActor.run {
            currentCoords = (lat, lng)
            isPrefetching = true
        }
        async let spotsTask = try? await APIClient.shared.fetchNearbySpots(lat: lat, lng: lng)
        async let catsTask  = try? await APIClient.shared.fetchSpotCategories()
        let (spots, cats) = await (spotsTask, catsTask)
        await MainActor.run {
            nearbySpots = spots ?? []   // el más cercano viene primero del backend
            if let cats { categories = cats }
            isPrefetching = false
        }
    }

    /// Solo se llega aquí cuando el catálogo no tiene nada cerca: no hay qué
    /// elegir, así que va directo al formulario para nombrar el lugar.
    private func useCurrentLocation() {
        guard let loc = LocationService.current?.userLocation else {
            errorMessage = "No pudimos obtener tu ubicación. Activa el GPS o busca el lugar manualmente."
            LocationService.current?.requestPermission()
            LocationService.current?.startTracking()
            return
        }
        Haptic.medium()
        errorMessage = nil
        currentCoords = (loc.coordinate.latitude, loc.coordinate.longitude)
        step = .propose
    }


    /// Sin spots cerca: el buddy nombra el lugar. Queda pendiente de aprobación
    /// en el admin, pero puede documentarlo desde ya.
    @ViewBuilder
    private var proposePlaceStep: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("NO ENCONTRAMOS ESTE LUGAR")
                .font(BT.eyebrow)
                .tracking(2)
                .foregroundStyle(Color.inkMuted)
                .padding(.top, Spacing.lg)

            Text("¿Cómo se llama?")
                .font(BT.title3)
                .foregroundStyle(Color.ink)

            Text("Escríbelo y lo agregamos al mapa de la comunidad\ndespués de revisarlo.")
                .font(BT.footnote)
                .foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Ej. Cafetería Rosal", text: $proposedName)
                .font(BT.callout)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 14)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                .submitLabel(.done)
                .onSubmit { submitProposal() }

            // Categoría: la elige quien está viendo el local, así la propuesta
            // llega clasificada al admin en vez de tener que adivinarla.
            if !categories.isEmpty {
                Text("¿QUÉ TIPO DE LUGAR ES?")
                    .font(BT.eyebrow)
                    .tracking(2)
                    .foregroundStyle(Color.inkMuted)
                    .padding(.top, Spacing.xs)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(categories) { category in
                            let isSelected = selectedCategoryId == category.id
                            Button {
                                Haptic.select()
                                // Volver a tocar la misma categoría la deselecciona.
                                selectedCategoryId = isSelected ? nil : category.id
                            } label: {
                                HStack(spacing: 6) {
                                    if let icon = category.icon {
                                        Image(systemName: icon).font(.system(size: 12))
                                    }
                                    Text(category.name).font(BT.footnote)
                                }
                                .padding(.horizontal, Spacing.md)
                                .padding(.vertical, 9)
                                .background(isSelected ? Color.ink : Color.surface)
                                .foregroundStyle(isSelected ? Color.inkInverse : Color.ink)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(isSelected ? Color.clear : Color.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)   // el borde del primer/último chip no se recorta
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(BT.caption1)
                    .foregroundStyle(Color.red)
            }

            Button { submitProposal() } label: {
                HStack(spacing: Spacing.sm) {
                    if isSubmitting { ProgressView().scaleEffect(0.8).tint(Color.inkInverse) }
                    Text("Compartir aquí").font(BT.footnoteBold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(proposedName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.inkMuted : Color.ink)
                .foregroundStyle(Color.inkInverse)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || proposedName.trimmingCharacters(in: .whitespaces).isEmpty)

            Button { step = .map } label: {
                Text("Buscar en el mapa")
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(.horizontal, Spacing.edge)
    }

    private func submitProposal() {
        let name = proposedName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let coords = currentCoords else { return }
        submitProposal(name: name, categoryId: selectedCategoryId, coords: coords, origin: "gps")
    }

    /// Con un punto elegido en el mapa manda ESE; sin él, donde está el buddy.
    private func submitProposal(name: String, categoryId: String?, coords: (lat: Double, lng: Double), origin: String) {
        guard !isSubmitting else { return }
        Haptic.medium()
        errorMessage = nil
        isSubmitting = true
        dlog("📍 [CompartirLugarSheet] proposeSpot \"\(name)\" origen=\(origin) coords=(\(coords.lat),\(coords.lng))")
        Task {
            do {
                let spot = try await APIClient.shared.proposeSpot(
                    name: name, lat: coords.lat, lng: coords.lng, categoryId: categoryId
                )
                dlog("📍 [CompartirLugarSheet] proposeSpot ok id=\(spot.id.prefix(8))")
                let journey = try await APIClient.shared.createJourney(spotId: spot.id, attachToTrip: false)
                await MainActor.run {
                    isSubmitting = false
                    dismiss()
                    onCreated(journey)
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "No pudimos registrar este lugar. Inténtalo de nuevo."
                    print("❌ [CompartirLugarSheet] proposeSpot failed: \(error)")
                }
            }
        }
    }

    // MARK: – Paso 2: buscar en el mapa

    @ViewBuilder
    private var mapStep: some View {
        ElegirLugarEnMapaView(
            // La ubicación de ESTE momento si hay: currentCoords solo existe
            // si el prefetch ya terminó, y el mapa no debe abrir en el mundo.
            initialCoords: mapStart ?? currentCoords,
            categories: categories,
            isSubmitting: isSubmitting,
            errorMessage: errorMessage,
            onPickSpot: { spot in
                Haptic.medium()
                errorMessage = nil
                dlog("📍 [CompartirLugarSheet] lugar del mapa elegido \(spot.id.prefix(8)) \"\(spot.name)\"")
                submit(spotId: spot.id)
            },
            onPropose: { name, categoryId, lat, lng in
                submitProposal(name: name, categoryId: categoryId, coords: (lat, lng), origin: "mapa")
            }
        )
    }

    // MARK: – Envío común

    private func submit(destinationId: String? = nil, placeId: String? = nil, spotId: String? = nil, lat: Double? = nil, lng: Double? = nil) {
        isSubmitting = true
        Task {
            do {
                let journey = try await APIClient.shared.createJourney(
                    destinationId: destinationId,
                    placeId: placeId,
                    spotId: spotId,
                    lat: lat,
                    lng: lng,
                    attachToTrip: false
                )
                await MainActor.run {
                    isSubmitting = false
                    dismiss()
                    onCreated(journey)
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = "No pudimos compartir este lugar. Inténtalo de nuevo."
                    print("❌ [CompartirLugarSheet] createJourney failed: \(error)")
                }
            }
        }
    }
}

// MARK: - Mapa: "Buscar en el mapa"

/// "Buscar en el mapa" — estilo inDrive: el pin queda FIJO en el centro con una
/// línea fina debajo cuya punta marca el punto; el buddy mueve el mapa por
/// debajo y, al soltar, se carga la dirección de ese punto.
///
/// Dos caminos sobre el mismo mapa, y los dos terminan en lo que ya existía:
///  - tocar un lugar que YA está en el mapa → "Elegir este lugar", igual que
///    elegirlo de la lista de cercanos;
///  - dejar el pin sobre un punto libre → se piden los mismos datos que en
///    "Registrar nuevo lugar" (nombre y tipo). El lugar se propone con las
///    coordenadas del CENTRO, no con las del GPS.
///
/// Los lugares existentes se piden por rectángulo visible (places/in-bounds),
/// el mismo endpoint del mapa del destino.
struct ElegirLugarEnMapaView: View {
    let categories: [APISpotCategory]
    let isSubmitting: Bool
    let errorMessage: String?
    let onPickSpot: (APIPlaceGuideSpot) -> Void
    let onPropose: (_ name: String, _ categoryId: String?, _ lat: Double, _ lng: Double) -> Void

    let initialCoords: (lat: Double, lng: Double)?
    private let openedAt = Date()
    @State private var releasedAt: Date?

    @State private var camera: MapCameraPosition
    @State private var spots: [APIPlaceGuideSpot] = []
    @State private var selectedId: String?
    @State private var center: CLLocationCoordinate2D?
    @State private var isMoving = false
    @State private var address: String?
    @State private var geocodeTask: Task<Void, Never>?
    @State private var name = ""
    @State private var categoryId: String?
    @State private var tooWide = false
    @State private var fetched: SpotBounds?
    @State private var boundsTask: Task<Void, Never>?
    @State private var lastRegion: MKCoordinateRegion?
    /// onEnd llega varias veces por gesto (4–14 en los logs, en el mismo ms) y
    /// cada una pedía otra dirección: el geocoder se ahogaba (1.9 s, 3.6 s).
    @State private var lastHandled: CLLocationCoordinate2D?
    @State private var ignoredEnds = 0

    // Búsqueda por texto: mueve el mapa, no elige nada por sí sola.
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    init(
        initialCoords: (lat: Double, lng: Double)?,
        categories: [APISpotCategory],
        isSubmitting: Bool,
        errorMessage: String?,
        onPickSpot: @escaping (APIPlaceGuideSpot) -> Void,
        onPropose: @escaping (_ name: String, _ categoryId: String?, _ lat: Double, _ lng: Double) -> Void
    ) {
        self.initialCoords = initialCoords
        self.categories = categories
        self.isSubmitting = isSubmitting
        self.errorMessage = errorMessage
        self.onPickSpot = onPickSpot
        self.onPropose = onPropose
        if let c = initialCoords {
            let coord = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng)
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: coord, span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
            )))
            _center = State(initialValue: coord)
        } else {
            _camera = State(initialValue: .automatic)
        }
    }

    /// "ms desde que se abrió el mapa" — para validar tiempos en los logs.
    private func ms(_ since: Date? = nil) -> Int { Int(Date().timeIntervalSince(since ?? openedAt) * 1000) }

    private var selected: APIPlaceGuideSpot? { spots.first { $0.id == selectedId } }

    var body: some View {
        // VStack y no safeAreaInset: el pin se centra sobre ESTE marco, y el
        // centro del mapa tiene que ser el mismo punto.
        VStack(spacing: 0) {
            ZStack {
                Map(position: $camera) {
                    ForEach(spots.sorted { $0.id != selectedId && $1.id == selectedId }) { spot in
                        Annotation("", coordinate: CLLocationCoordinate2D(latitude: spot.lat, longitude: spot.lng)) {
                            spotPin(label: spot.name, glyph: spot.placeCategory?.icon, isSelected: selectedId == spot.id)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                                .highPriorityGesture(TapGesture().onEnded {
                                    guard !isSubmitting else { return }
                                    Haptic.select()
                                    dlog("📍 [ElegirLugarMapa] pin existente tocado \(spot.id.prefix(8)) \"\(spot.name)\" pendiente=\(spot.isPendingApproval)")
                                    selectedId = spot.id
                                })
                        }
                        .annotationTitles(.hidden)
                    }
                    UserAnnotation()
                }
                .mapControls { MapUserLocationButton() }
                // Mientras se arrastra: el pin se levanta. Al soltar: baja,
                // se toma el centro y se carga la dirección.
                .onMapCameraChange(frequency: .continuous) { _ in
                    guard !isMoving else { return }
                    isMoving = true
                    selectedId = nil
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    isMoving = false
                    lastRegion = context.region
                    // Menos de 3 m respecto al último centro atendido: es el
                    // mismo reposo repetido, no un movimiento nuevo.
                    if let prev = lastHandled {
                        let d = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
                            .distance(from: CLLocation(latitude: context.region.center.latitude, longitude: context.region.center.longitude))
                        if d < 3 { ignoredEnds += 1; return }
                    }
                    lastHandled = context.region.center
                    center = context.region.center
                    releasedAt = Date()
                    dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] mapa detenido — centro=(\(context.region.center.latitude),\(context.region.center.longitude)) (\(ignoredEnds) evento(s) repetido(s) ignorado(s))")
                    ignoredEnds = 0
                    geocode(context.region.center)
                    loadSpots(region: context.region)
                }

                if selected == nil { centerPin }
            }
            .overlay(alignment: .top) { topBar }

            panel
        }
        .onAppear {
            dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] abierto — ubicación=\(initialCoords.map { "(\($0.lat),\($0.lng))" } ?? "AÚN NO") categorias=\(categories.count)")
            if let c = center { geocode(c) }
        }
        // La ubicación pudo llegar DESPUÉS de abrir (el sheet la pide al
        // abrirse): si el mapa nació sin centro, se mueve ahí en cuanto llega.
        .onChange(of: initialCoords?.lat) { _, lat in
            guard center == nil, let c = initialCoords, lat != nil else { return }
            dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] ubicación llegó tarde → centrando en (\(c.lat),\(c.lng))")
            let coord = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng)
            camera = .region(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
            center = coord
            geocode(coord)
        }
    }

    // MARK: – Búsqueda por texto

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.inkMuted).font(.system(size: 15))
                TextField("Buscar un lugar o dirección", text: $searchText)
                    .font(BT.callout)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onChange(of: searchText) { _, q in triggerSearch(q) }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.md).padding(.vertical, 12)
            .background(Color.surface, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)

            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(searchResults.enumerated()), id: \.offset) { i, item in
                        Button { goTo(item) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? "Sin nombre").font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(1)
                                if let sub = item.placemark.title {
                                    Text(sub).font(BT.caption1).foregroundStyle(Color.inkMuted).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.md).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if i < searchResults.count - 1 { Divider() }
                    }
                }
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            } else if tooWide {
                Text("Acércate para ver los lugares")
                    .font(BT.footnote)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.surface, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            }
        }
        .padding(.horizontal, Spacing.edge)
        .padding(.top, Spacing.sm)
    }

    /// 400 ms sin teclear, y se busca cerca de lo que el mapa muestra: "café"
    /// debe encontrar los de aquí, no los de otra ciudad.
    private func triggerSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            if !searchResults.isEmpty { dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] búsqueda vacía/corta — limpio resultados") }
            searchResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let started = Date()
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = q
            let around = lastRegion?.center ?? center
            if let r = lastRegion { request.region = r }
            dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] búsqueda \"\(q)\" iniciada — región=\(lastRegion.map { "centro (\($0.center.latitude),\($0.center.longitude)) span \($0.span.latitudeDelta)°" } ?? "ninguna")")
            do {
                let items = try await MKLocalSearch(request: request).start().mapItems
                guard !Task.isCancelled else { return }
                await MainActor.run { searchResults = Array(items.prefix(5)) }
                dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] búsqueda \"\(q)\" → \(items.count) resultado(s) en \(ms(started))ms (mostrando \(min(items.count, 5)))")
                for (i, item) in items.prefix(5).enumerated() {
                    let c = item.placemark.coordinate
                    let km = around.map {
                        CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) / 1000
                    }
                    dlog("📍 [ElegirLugarMapa]   \(i + 1). \"\(item.name ?? "?")\" — \(item.placemark.title ?? "sin dirección") (\(c.latitude),\(c.longitude)) a \(km.map { String(format: "%.1f", $0) } ?? "?") km del centro")
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] búsqueda \"\(q)\" FALLÓ en \(ms(started))ms: \(error.localizedDescription)")
                await MainActor.run { searchResults = [] }
            }
        }
    }

    private func goTo(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] búsqueda → \"\(item.name ?? "?")\" (\(coord.latitude),\(coord.longitude))")
        Haptic.select()
        searchFocused = false
        searchText = ""
        searchResults = []
        selectedId = nil
        withAnimation {
            camera = .region(MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
        }
    }

    // MARK: – Pin central (fijo) con su línea fina

    /// La PUNTA de la línea es el punto elegido: queda exactamente en el centro
    /// del mapa. Los offsets son fijos para que la punta no se mueva cuando
    /// cambia el texto de la etiqueta.
    private var centerPin: some View {
        let lift: CGFloat = isMoving ? 10 : 0
        return ZStack {
            // Marca en el suelo: dónde cae realmente el punto mientras el pin flota.
            Circle().fill(Color.ink.opacity(0.25)).frame(width: 6, height: 3 * 2).scaleEffect(y: 0.5)
            Rectangle().fill(Color.ink).frame(width: 2, height: 16)
                .offset(y: -8 - lift)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.ink)
                Image(systemName: "mappin")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.inkInverse)
            }
            .frame(width: 36, height: 36)
            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            .offset(y: -(16 + 18) - lift)
            addressBubble
                .offset(y: -(16 + 36 + 8 + 20) - lift)
        }
        .animation(.easeOut(duration: 0.15), value: isMoving)
        .allowsHitTesting(false)
    }

    private var addressBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Punto elegido").font(BT.caption2).foregroundStyle(Color.inkMuted)
            Text(isMoving ? "…" : (address ?? "Buscando dirección…"))
                .font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        .frame(maxWidth: 240)
    }

    /// Mismo pin que el mapa normal (RecommendationPin): círculo con el ICONO de
    /// la categoría del lugar. Sin categoría cae al genérico, como allá.
    private func spotPin(label: String, glyph: String?, isSelected: Bool) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(Color.surface)
                    .overlay(Circle().strokeBorder(Color.teal.opacity(isSelected ? 0.9 : 0.3),
                                                   lineWidth: isSelected ? 2 : 1.25))
                Image(systemName: glyph ?? "building.columns")
                    .font(.system(size: isSelected ? 17 : 14, weight: .semibold))
                    .foregroundStyle(Color.teal)
            }
            .frame(width: isSelected ? 40 : 33, height: isSelected ? 40 : 33)
            .shadow(color: .black.opacity(0.18), radius: isSelected ? 8 : 3, y: 1.5)
            // El nombre va SIEMPRE: aquí es la pista para saber si el lugar que
            // el buddy busca ya existe antes de crear uno nuevo.
            Text(label)
                .font(isSelected ? BT.caption1 : BT.caption2)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.white, in: Capsule())
                .frame(maxWidth: isSelected ? 150 : 110)
        }
    }

    // MARK: – Dirección del centro

    private func geocode(_ coord: CLLocationCoordinate2D) {
        geocodeTask?.cancel()
        address = nil
        geocodeTask = Task {
            // 250 ms: si el mapa se vuelve a mover, esta petición ni sale.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let started = Date()
            let marks = try? await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            )
            guard !Task.isCancelled else { return }
            let text = marks?.first.flatMap { Self.format($0) }
            await MainActor.run { address = text ?? "Sin dirección" }
            let sinceRelease = await MainActor.run { releasedAt.map { ", \(ms($0))ms desde que soltaste el mapa" } ?? "" }
            dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] dirección=\(text ?? "nil") — geocoder \(ms(started))ms\(sinceRelease)")
        }
    }

    private static func format(_ p: CLPlacemark) -> String? {
        let street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        if !street.isEmpty { return street }
        return p.name ?? p.locality
    }

    // MARK: – Panel inferior

    @ViewBuilder
    private var panel: some View {
        if let spot = selected {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(spot.isPendingApproval ? "LUGAR POR REVISAR" : "LUGAR EN EL MAPA")
                    .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                Text(spot.name).font(BT.title3).foregroundStyle(Color.ink).lineLimit(2)
                if let errorMessage {
                    Text(errorMessage).font(BT.caption1).foregroundStyle(Color.red)
                }
                primaryButton(title: "Elegir este lugar", enabled: !isSubmitting, loading: isSubmitting) {
                    dlog("📍 [ElegirLugarMapa] elegir lugar existente \(spot.id.prefix(8))")
                    onPickSpot(spot)
                }
            }
            .panelStyle()
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("NUEVO LUGAR").font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                TextField("¿Cómo se llama? Ej. Cafetería Rosal", text: $name)
                    .font(BT.callout)
                    .padding(.horizontal, Spacing.md).padding(.vertical, 14)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                if !categories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(categories) { category in
                                let isSelected = categoryId == category.id
                                Button {
                                    Haptic.select()
                                    categoryId = isSelected ? nil : category.id
                                } label: {
                                    Text(category.name).font(BT.footnote)
                                        .padding(.horizontal, Spacing.md).padding(.vertical, 9)
                                        .background(isSelected ? Color.ink : Color.surface)
                                        .foregroundStyle(isSelected ? Color.inkInverse : Color.ink)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(BT.caption1).foregroundStyle(Color.red)
                }
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                primaryButton(
                    title: "Compartir aquí",
                    enabled: !trimmed.isEmpty && !isSubmitting && center != nil && !isMoving,
                    loading: isSubmitting
                ) {
                    guard let c = center else { return }
                    dlog("📍 [ElegirLugarMapa] proponer \"\(trimmed)\" cat=\(categoryId?.prefix(8) ?? "nil") en (\(c.latitude),\(c.longitude)) dir=\(address ?? "nil")")
                    onPropose(trimmed, categoryId, c.latitude, c.longitude)
                }
            }
            .panelStyle()
        }
    }

    private func primaryButton(title: String, enabled: Bool, loading: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptic.medium()
            action()
        } label: {
            HStack(spacing: Spacing.sm) {
                if loading { ProgressView().scaleEffect(0.8).tint(Color.inkInverse) }
                Text(title).font(BT.footnoteBold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(enabled ? Color.ink : Color.inkMuted)
            .foregroundStyle(Color.inkInverse)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: – Lugares del rectángulo visible

    /// Mismo patrón que el mapa del destino: 600 ms sin gestos, se pide el doble
    /// de lo visible y solo se vuelve a pedir al salir de ese margen.
    private func loadSpots(region: MKCoordinateRegion) {
        let visible = SpotBounds(region: region, scale: 1)
        if let ya = fetched, !ya.truncated, ya.contains(visible) { return }
        boundsTask?.cancel()
        boundsTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let pedido = SpotBounds(region: region, scale: 2)
            let requestedAt = Date()
            do {
                let res = try await APIClient.shared.fetchSpotsInBounds(
                    minLat: pedido.minLat, minLng: pedido.minLng,
                    maxLat: pedido.maxLat, maxLng: pedido.maxLng
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    tooWide = res.tooWide == true
                    guard !tooWide else { return }
                    fetched = SpotBounds(minLat: pedido.minLat, minLng: pedido.minLng,
                                         maxLat: pedido.maxLat, maxLng: pedido.maxLng,
                                         truncated: res.truncated == true)
                    if res.spots.map(\.id) != spots.map(\.id) { spots = res.spots }
                }
                dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] en pantalla: \(res.spots.count) lugar(es)\(res.tooWide == true ? " (demasiado lejos)" : "") — red \(ms(requestedAt))ms")
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                dlog("📍 [ElegirLugarMapa] spotsInBounds falló (\(error.localizedDescription)) — conservo \(spots.count)")
            }
        }
    }
}

private extension View {
    func panelStyle() -> some View {
        self
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.lg, topTrailingRadius: Radius.lg))
            .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
    }
}
