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
    /// Tocar un lugar cercano abre su mapa para añadir fotos (Keyla, 25 Nov 2026).
    var onOpenPlace: ((APIPlaceCard) -> Void)? = nil

    init(onOpenPlace: ((APIPlaceCard) -> Void)? = nil, onCreated: @escaping (APIJourney) -> Void) {
        self.onOpenPlace = onOpenPlace
        self.onCreated = onCreated
    }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .choose
    @State private var isSubmitting = false
    @State private var submittingId: String?
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
            .navigationTitle("Recomendar un lugar")
            .navigationBarTitleDisplayMode(.inline)
            // Barra estándar y sólida (Keyla, 25 Nov 2026): el mapa empieza debajo,
            // así "Cancelar" y la búsqueda no flotan sobre el mapa.
            .toolbarBackground(Color.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task { await prefetchNearby() }
            .toolbar {
                // Botón atrás estándar en todos los pasos (Keyla, 25 Nov 2026):
                // en el mapa vuelve al paso 1; en el paso 1 cierra.
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if step == .choose { dismiss() } else { withAnimation { step = .choose } }
                    } label: {
                        Image(systemName: "chevron.left").fontWeight(.semibold)
                    }
                    .accessibilityLabel("Atrás")
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    // MARK: – Paso 1: elegir origen del lugar

    @ViewBuilder
    private var chooseStep: some View {
        VStack(spacing: Spacing.md) {
            // Pregunta en positivo (Keyla, 25 Nov 2026): se recomienda lo que gustó.
            VStack(alignment: .leading, spacing: 4) {
                Text("¿Qué lugar te encantó?")
                    .font(BT.title3)
                    .foregroundStyle(Color.ink)
                Text("Recomienda un sitio donde tuviste una buena experiencia.")
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Spacing.lg)

            // Los locales cercanos se listan aquí mismo. Si el botón ya dice el
            // nombre, tocarlo ES la elección — una segunda pantalla preguntando
            // "¿en cuál estás?" repetiría la pregunta que este botón responde.
            // Los cercanos con la misma tarjeta de "Cerca de ti" en Inicio
            // (Keyla, 25 Nov 2026): tocar una tarjeta ES la elección.
            if !nearbySpots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(nearbySpots.prefix(5)) { spot in
                            Button {
                                Haptic.medium()
                                if let onOpenPlace { dismiss(); onOpenPlace(spot.asPlaceCard) }
                                else { submit(spotId: spot.id) }
                            } label: {
                                HomePlaceCard(card: spot.asPlaceCard, large: false, tall: true, showsDistance: true)
                                    .overlay {
                                        if isSubmitting && submittingId == spot.id {
                                            RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.25))
                                            ProgressView().tint(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.pressable)
                            .disabled(isSubmitting)
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.vertical, 4)
                }
                .padding(.horizontal, -Spacing.edge)
            }

            // "Registrar lugar de la ubicación actual" quitado (Keyla, 21 Nov 2026):
            // un lugar nuevo se marca en "Buscar en el mapa".
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
        PlaceOptionRow(icon: icon, title: title, subtitle: subtitle, isLoading: isLoading)
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
        submittingId = spotId
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
    /// Textos del panel: por defecto los de "Compartir un lugar". Mi negocio
    /// usa el mismo mapa para sus ubicaciones con sus propios textos.
    var pickTitle = "Elegir este lugar"
    var proposeTitle = "Compartir aquí"
    var newEyebrow = "NUEVO LUGAR"
    var namePlaceholder = "¿Cómo se llama? Ej. Cafetería Rosal"
    /// Sugerir los lugares del mapa (Apple Maps) que están junto al pin, aunque
    /// nadie los haya recomendado en Buddy. Tocar uno pone su nombre y centra
    /// el pin ahí (Keyla, 20 Nov 2026: ubicaciones del negocio).
    var suggestMapPlaces = false
    /// Nombre ya conocido (la sede se llama como el negocio): sin campo de texto.
    var fixedName: String? = nil
    /// Lugar a mostrar primero (tocado en la lista): el mapa abre ahí y, si es
    /// de Buddy, lo deja elegido con su foto. Nada se guarda sin el botón.
    var focusSpotId: String? = nil
    /// Deslizar a la derecha sobre el panel vuelve atrás, como el mapa de un lugar.
    var onSwipeBack: (() -> Void)? = nil
    /// Panel jalado hacia arriba: tapa el mapa, como el detalle de un lugar.
    @State private var detailExpanded = false
    /// Abrir o cerrar el panel cambia el tamaño del mapa: eso no es un arrastre.
    @State private var ignoreCameraUntil = Date.distantPast
    private func setExpanded(_ v: Bool) {
        ignoreCameraUntil = Date().addingTimeInterval(0.8)
        withAnimation(TripDetailView.panelSpring) { detailExpanded = v }
    }
    @State private var mapPlaces: [MKMapItem] = []
    @State private var poiTask: Task<Void, Never>?
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
    /// El buscador muestra el punto elegido sin lanzar una búsqueda (Keyla, 25 Nov 2026).
    @State private var autoFill = false
    /// Ruedita mientras se busca (Keyla, 25 Nov 2026): con 3G la búsqueda tarda.
    @State private var isSearching = false
    @State private var searchRun = 0
    @State private var searchResults: [MKMapItem] = []
    /// Lugares de Buddy que coinciden: van primero (Keyla, 21 Nov 2026).
    @State private var buddyResults: [APINearbySpot] = []
    @State private var pendingSelectId: String?
    /// Movimiento del mapa hecho por la app (centrar el lugar elegido): no
    /// debe soltar la selección como lo hace un arrastre del usuario.
    @State private var programmaticMove = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    init(
        initialCoords: (lat: Double, lng: Double)?,
        categories: [APISpotCategory],
        isSubmitting: Bool,
        errorMessage: String?,
        onPickSpot: @escaping (APIPlaceGuideSpot) -> Void,
        onPropose: @escaping (_ name: String, _ categoryId: String?, _ lat: Double, _ lng: Double) -> Void,
        pickTitle: String = "Elegir este lugar",
        proposeTitle: String = "Compartir aquí",
        newEyebrow: String = "NUEVO LUGAR",
        namePlaceholder: String = "¿Cómo se llama? Ej. Cafetería Rosal",
        suggestMapPlaces: Bool = false,
        fixedName: String? = nil,
        focus: (lat: Double, lng: Double)? = nil,
        focusSpotId: String? = nil,
        onSwipeBack: (() -> Void)? = nil
    ) {
        self.onSwipeBack = onSwipeBack
        self.suggestMapPlaces = suggestMapPlaces
        self.fixedName = fixedName
        self.focusSpotId = focusSpotId
        let initialCoords = focus ?? initialCoords
        self.pickTitle = pickTitle
        self.proposeTitle = proposeTitle
        self.newEyebrow = newEyebrow
        self.namePlaceholder = namePlaceholder
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
        } else if fixedName != nil {
            // Sin ubicación del teléfono: empezar en Villa Rica, no en el océano.
            let coord = CLLocationCoordinate2D(latitude: -10.7395, longitude: -75.2698)
            _camera = State(initialValue: .region(MKCoordinateRegion(
                center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))))
            _center = State(initialValue: coord)
        } else {
            _camera = State(initialValue: .automatic)
        }
    }

    /// "ms desde que se abrió el mapa" — para validar tiempos en los logs.
    private func ms(_ since: Date? = nil) -> Int { Int(Date().timeIntervalSince(since ?? openedAt) * 1000) }

    private var selected: APIPlaceGuideSpot? { spots.first { $0.id == selectedId } }
    @Namespace private var mapScope
    /// Lugar de Apple tocado en el mapa (Plaza de Armas, hospedajes, cafés…).
    @State private var mapFeature: MapFeature?

    var body: some View {
        // VStack y no safeAreaInset: el pin se centra sobre ESTE marco, y el
        // centro del mapa tiene que ser el mismo punto.
        VStack(spacing: 0) {
            ZStack {
                Map(position: $camera, selection: $mapFeature, scope: mapScope) {
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
                                    centerOn(spot)
                                })
                        }
                        .annotationTitles(.hidden)
                    }
                    UserAnnotation()
                }
                // El botón de ubicación va abajo a la derecha: arriba quedaba
                // escondido detrás de la búsqueda (Keyla, 25 Nov 2026).
                .mapControls { }
                // Tocar o mover el mapa cierra el teclado (Keyla, 25 Nov 2026), como en Android.
                .simultaneousGesture(TapGesture().onEnded { closeKeyboard() })
                .simultaneousGesture(DragGesture(minimumDistance: 2).onChanged { _ in closeKeyboard() })
                // Tocar un lugar del mapa: el pin va ahí y su nombre llena
                // "Nuevo lugar" (Keyla, 25 Nov 2026).
                .onChange(of: mapFeature) { _, f in
                    guard let f else { return }
                    Haptic.select()
                    selectedId = nil
                    // En Mi negocio el nombre es el del negocio: solo se mueve el punto.
                    if let t = f.title, !t.isEmpty { if fixedName == nil { name = t }; autoFill = true; searchText = t }
                    center = f.coordinate
                    programmaticMove = true
                    withAnimation {
                        camera = .region(MKCoordinateRegion(center: f.coordinate,
                                                            span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Acercar / alejar (Keyla, 25 Nov 2026), encima del botón de ubicación.
                    VStack(spacing: 8) {
                        zoomButton("plus", label: "Acercar", factor: 0.4)
                        zoomButton("minus", label: "Alejar", factor: 2.5)
                        if LocationService.current?.userLocation != nil {
                            mapButton("location.fill", label: "Mi ubicación") { goToUser() }
                        }
                    }
                    .padding(Spacing.edge)
                    // En la ubicación del negocio el panel flota encima del mapa: los botones suben.
                    .padding(.bottom, fixedName != nil ? 230 : 0)
                }
                // Mientras se arrastra: el pin se levanta. Al soltar: baja,
                // se toma el centro y se carga la dirección.
                .onMapCameraChange(frequency: .continuous) { _ in
                    guard !isMoving, !programmaticMove, !detailExpanded, Date() > ignoreCameraUntil else { return }
                    isMoving = true
                    // Se aleja del lugar de Apple: su nombre ya no corresponde al punto.
                    if let f = mapFeature, let t = f.title, name == t { name = "" }
                    mapFeature = nil
                    selectedId = nil
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    isMoving = false
                    if programmaticMove {
                        programmaticMove = false; lastRegion = context.region
                        // Elegido desde la búsqueda: queda seleccionado al llegar.
                        if let id = pendingSelectId, spots.contains(where: { $0.id == id }) { selectedId = id; pendingSelectId = nil }
                        return
                    }
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
                    // Al mover el mapa la búsqueda se repite en la nueva zona (Keyla, 25 Nov 2026).
                    if searchFocused, !searchText.trimmingCharacters(in: .whitespaces).isEmpty { triggerSearch(searchText) }
                }

                // Con un lugar de Apple elegido se ve solo su marca, sin nuestro pin encima.
                if selected == nil && mapFeature == nil { centerPin }
            }
            // Ubicación de un negocio: el panel va ENCIMA del mapa, como el mapa de
            // un lugar. Así al jalarlo hacia arriba tapa el mapa sin encogerlo.
            .overlay(alignment: .bottom) { if fixedName != nil { panel } }

            if fixedName == nil { panel }
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

    private var topBar: some View { searchBlock(inline: false) }

    private func closeKeyboard() {
        guard searchFocused else {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return
        }
        searchFocused = false
    }

    private func isNear(_ item: MKMapItem, _ around: CLLocationCoordinate2D?, _ radius: Double) -> Bool {
        guard let a = around else { return true }
        let c = item.placemark.coordinate
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)) < radius
    }

    /// Direcciones parecidas cuando la búsqueda exacta no encuentra nada.
    private func similarAddresses(_ q: String, region: MKCoordinateRegion?) async -> [MKMapItem] {
        var out: [MKMapItem] = []
        // 1. El geocodificador entiende "calle número".
        let geo = CLGeocoder()
        let circle = region.map { CLCircularRegion(center: $0.center, radius: 50_000, identifier: "zona") }
        if let marks = try? await geo.geocodeAddressString(q, in: circle, preferredLocale: Locale(identifier: "es_PE")) {
            out += marks.map { MKMapItem(placemark: MKPlacemark(placemark: $0)) }
        }
        // 2. Sin números: "Francisco Arana 218" → "Francisco Arana".
        let words = q.split(separator: " ").filter { $0.rangeOfCharacter(from: .decimalDigits) == nil }
        let shorter = words.joined(separator: " ")
        if shorter.count >= 2, shorter != q {
            let r = MKLocalSearch.Request()
            r.naturalLanguageQuery = shorter
            if let region { r.region = region }
            if let items = try? await MKLocalSearch(request: r).start().mapItems { out += items }
        }
        return out
    }

    private func zoomButton(_ icon: String, label: String, factor: Double) -> some View {
        mapButton(icon, label: label) {
            guard let r = lastRegion else { return }
            let span = MKCoordinateSpan(latitudeDelta: min(max(r.span.latitudeDelta * factor, 0.001), 60),
                                        longitudeDelta: min(max(r.span.longitudeDelta * factor, 0.001), 60))
            withAnimation { camera = .region(MKCoordinateRegion(center: r.center, span: span)) }
        }
    }

    /// Volver a donde está la persona (antes el botón de Apple, que a veces salía en blanco).
    private func goToUser() {
        guard let loc = LocationService.current?.userLocation else { return }
        withAnimation {
            camera = .region(MKCoordinateRegion(center: loc.coordinate,
                                                span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)))
        }
    }

    /// Botón del mapa: el MISMO componente que el mapa de un lugar (MapIconButton
    /// con vidrio redondeado), para acercar, alejar y mi ubicación (Keyla, 25 Nov 2026).
    private func mapButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        MapIconButton(icon: icon) { Haptic.light(); action() }
            .glassRounded(14)
            .mapControlShadow()
            .accessibilityLabel(label)
    }

    /// Búsqueda. inline = dentro del panel de abajo, encima de "Nuevo lugar"
    /// (Keyla, 25 Nov 2026): el mapa queda libre arriba.
    private func searchBlock(inline: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.inkMuted).font(.system(size: 15))
                TextField("Buscar un lugar o dirección", text: $searchText)
                    .font(BT.callout)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onChange(of: searchText) { _, q in
                        if autoFill { autoFill = false; return }
                        triggerSearch(q)
                    }
                if isSearching {
                    ProgressView().controlSize(.small).tint(Color.brand)
                }
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
            .background(inline ? Color.sageTint.opacity(0.5) : Color.surface, in: Capsule())
            .shadow(color: .black.opacity(inline ? 0 : 0.12), radius: 4, y: 1)

            if !searchResults.isEmpty || !buddyResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(buddyResults.prefix(inline ? 3 : 5)) { spot in
                        Button { goTo(spot) } label: {
                            HStack(spacing: 10) {
                                LocationPin(size: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(spot.name).font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(1)
                                    if let d = spot.destination?.name ?? (spot.distanceMeters != nil ? spot.distanceLabel : nil) {
                                        Text(d).font(BT.caption1).foregroundStyle(Color.inkMuted).lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.md).padding(.vertical, 10)
                            .contentShape(Rectangle())   // toda la fila se puede tocar
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                    ForEach(Array(searchResults.prefix(inline ? 4 : 8).enumerated()), id: \.offset) { i, item in
                        Button { goTo(item) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name ?? "Sin nombre").font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(1)
                                if let sub = item.placemark.title {
                                    Text(sub).font(BT.caption1).foregroundStyle(Color.inkMuted).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.md).padding(.vertical, 10)
                            .contentShape(Rectangle())   // toda la fila se puede tocar
                        }
                        .buttonStyle(.plain)
                        if i < min(searchResults.count, inline ? 4 : 8) - 1 { Divider() }
                    }
                }
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: inline ? 1 : 0))
                .shadow(color: .black.opacity(inline ? 0 : 0.12), radius: 4, y: 1)
            }
        }
        .padding(.horizontal, inline ? 0 : Spacing.edge)
        .padding(.top, inline ? 0 : Spacing.sm)
    }

    /// 400 ms sin teclear, y se busca cerca de lo que el mapa muestra: "café"
    /// debe encontrar los de aquí, no los de otra ciudad.
    private func triggerSearch(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            if !searchResults.isEmpty { dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] búsqueda vacía/corta — limpio resultados") }
            searchResults = []; buddyResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchRun += 1
        let run = searchRun
        searchTask = Task {
            // Solo la búsqueda más reciente apaga la ruedita.
            defer { Task { @MainActor in if run == searchRun { isSearching = false } } }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let started = Date()
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = q
            let around = lastRegion?.center ?? center
            if let r = lastRegion { request.region = r }
            dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] búsqueda \"\(q)\" iniciada — región=\(lastRegion.map { "centro (\($0.center.latitude),\($0.center.longitude)) span \($0.span.latitudeDelta)°" } ?? "ninguna")")
            let c0 = around
            async let buddyTask = try? await APIClient.shared.searchCuratedSpots(query: q, lat: c0?.latitude, lng: c0?.longitude)
            do {
                // Sin resultados MapKit lanza error: igual se prueban direcciones parecidas.
                let raw = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
                try Task.checkCancellation()
                let buddy = await buddyTask ?? []
                guard !Task.isCancelled else { return }
                // De Apple solo lo cercano (50 km): "Finca Rosal" no debe traer Colombia.
                let taken = Set(buddy.map { $0.name.lowercased() })
                // Con el mapa alejado (todo el Perú) 50 km dejaba la lista vacía
                // (Keyla, 25 Nov 2026): el radio crece con lo que se ve en el mapa.
                let spanKm = (lastRegion.map { max($0.span.latitudeDelta, $0.span.longitudeDelta) } ?? 0) * 111
                let radius = max(50_000, spanKm * 1000 / 2 * 1.5)
                // Sin nada exacto ("Francisco Arana 218"): se prueba la dirección con
                // el geocodificador y luego sin el número (Keyla, 25 Nov 2026).
                var pool = raw
                if !raw.contains(where: { isNear($0, around, radius) }) {
                    pool += await similarAddresses(q, region: lastRegion)
                }
                // Cerca primero; si nada cercano coincide, también lo de más lejos en
                // todo el Perú, del más cercano al más lejano (Keyla, 25 Nov 2026).
                let fresh = pool.filter { !taken.contains(($0.name ?? "").lowercased()) }
                var items = fresh.filter { isNear($0, around, radius) }
                let words = q.lowercased().split(separator: " ").filter { $0.rangeOfCharacter(from: .decimalDigits) == nil }
                let matches: (MKMapItem) -> Bool = { item in
                    let n = (item.name ?? "").lowercased().folding(options: .diacriticInsensitive, locale: nil)
                    return words.allSatisfy { n.contains($0.folding(options: .diacriticInsensitive, locale: nil)) }
                }
                if !items.contains(where: matches) {
                    let r = MKLocalSearch.Request()
                    r.naturalLanguageQuery = q
                    r.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: -9.19, longitude: -75.0),
                                                  span: MKCoordinateSpan(latitudeDelta: 20, longitudeDelta: 20))
                    let wide = (try? await MKLocalSearch(request: r).start().mapItems) ?? []
                    let far = (fresh + wide).filter { !isNear($0, around, radius) && !taken.contains(($0.name ?? "").lowercased()) }
                    let dist: (MKMapItem) -> Double = { item in
                        guard let a = around else { return 0 }
                        let c = item.placemark.coordinate
                        return CLLocation(latitude: a.latitude, longitude: a.longitude)
                            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                    }
                    var seen = Set(items.map { "\($0.name ?? "")|\($0.placemark.coordinate.latitude)" })
                    for f in far.sorted(by: { dist($0) < dist($1) }) {
                        let key = "\(f.name ?? "")|\(f.placemark.coordinate.latitude)"
                        if seen.insert(key).inserted { items.append(f) }
                    }
                    // Lo que coincide con lo escrito va antes que lo "parecido".
                    items = items.filter(matches) + items.filter { !matches($0) }
                }
                await MainActor.run {
                    buddyResults = buddy
                    searchResults = Array(items.prefix(max(0, 5 - min(buddy.count, 5))))
                }
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

    private var expandedHeight: CGFloat {
        let top = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.top ?? 0
        // Debajo del título y del botón de volver.
        return UIScreen.main.bounds.height - max(top, 54) - 110
    }

    /// Como en el mapa de un lugar: el pin elegido queda a la vista, arriba del panel.
    private func centerOn(_ spot: APIPlaceGuideSpot) {
        guard fixedName != nil else { return }
        programmaticMove = true
        let span = 0.004
        withAnimation(.easeInOut(duration: 0.3)) {
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: spot.lat - span * 0.25, longitude: spot.lng),
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
        }
    }

    private func goTo(_ spot: APINearbySpot) {
        guard let lat = spot.lat, let lng = spot.lng else { return }
        Haptic.select()
        searchFocused = false
        searchText = ""
        searchResults = []; buddyResults = []
        pendingSelectId = spot.id
        programmaticMove = true
        let span = 0.004
        withAnimation(.easeInOut(duration: 0.3)) {
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: lat - span * 0.25, longitude: lng),
                                                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
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
                LocationPin(size: 18)
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
            await MainActor.run {
                address = text ?? "Sin dirección"
                // Al mover el mapa, el buscador muestra el lugar elegido.
                if !searchFocused, let text, text != searchText {
                    autoFill = true
                    searchText = text
                    searchResults = []; buddyResults = []
                }
            }
            if suggestMapPlaces { await loadMapPlaces(coord) }
            let sinceRelease = await MainActor.run { releasedAt.map { ", \(ms($0))ms desde que soltaste el mapa" } ?? "" }
            dlog("📍 [ElegirLugarMapa] [t+\(ms())ms] dirección=\(text ?? "nil") — geocoder \(ms(started))ms\(sinceRelease)")
        }
    }

    /// Lugares de Apple Maps a 80 m del pin, el más cercano primero.
    private func loadMapPlaces(_ coord: CLLocationCoordinate2D) async {
        let req = MKLocalPointsOfInterestRequest(center: coord, radius: 80)
        let items = (try? await MKLocalSearch(request: req).start().mapItems) ?? []
        let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        let sorted = items
            .filter { ($0.name ?? "").isEmpty == false }
            .sorted { here.distance(from: $0.placemark.location ?? here) < here.distance(from: $1.placemark.location ?? here) }
        await MainActor.run { mapPlaces = Array(sorted.prefix(6)) }
    }

    private func useMapPlace(_ item: MKMapItem) {
        Haptic.select()
        name = item.name ?? name
        let c = item.placemark.coordinate
        camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.002, longitudeDelta: 0.002)))
    }

    private static func format(_ p: CLPlacemark) -> String? {
        let street = [p.thoroughfare, p.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        if !street.isEmpty { return street }
        return p.name ?? p.locality
    }

    // MARK: – Panel inferior

    @ViewBuilder
    private var panel: some View {
        if let spot = selected, fixedName != nil {
            // Ubicación de un negocio: el mismo panel del mapa de siempre, en Fotos.
            VStack(spacing: 0) {
                // El mismo tirador del panel del mapa: tocarlo abre o cierra.
                Capsule().fill(Color.border).frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture { setExpanded(!detailExpanded) }
                    .padding(.bottom, -14)
                PlaceGuideDetailSheet(
                    place: spot.asPlace, destinationId: nil, buddyPresenceText: nil,
                    isFavorite: false, onToggleFavorite: {},
                    onNavigate: { onPickSpot(spot) },
                    onClose: { setExpanded(false); selectedId = nil },
                    expanded: detailExpanded,
                    actionTitle: pickTitle, actionIcon: "checkmark.circle", startOnPhotos: true
                )
                if detailExpanded { Spacer(minLength: 0) }
            }
            .fixedSize(horizontal: false, vertical: !detailExpanded)
            // Mismo alto mínimo que el detalle del mapa: no cambia al pasar de pestaña.
            .frame(minHeight: PlaceGuideDetailSheet.minHeight + 30, alignment: .top)
            .frame(height: detailExpanded ? expandedHeight : nil, alignment: .top)
            // El blanco llega hasta el borde de abajo, como el panel del mapa de un lugar.
            .background(UnevenRoundedRectangle(topLeadingRadius: Radius.lg, topTrailingRadius: Radius.lg)
                .fill(Color.surface).ignoresSafeArea(edges: .bottom))
            // Arriba: tapa el mapa. Abajo: vuelve. Derecha: atrás. Igual que el mapa de un lugar.
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { v in
                        let w = v.translation.width, h = v.predictedEndTranslation.height
                        if abs(v.translation.height) > abs(w) {
                            // Igual de sensible que el mapa de un lugar (Keyla, 23 Nov 2026).
                            if h < -30 { setExpanded(true) }
                            else if h > 30 { setExpanded(false) }
                        } else if w > 90, w > abs(h) * 2 || v.predictedEndTranslation.width > 220 && w > abs(h) * 2 {
                            Haptic.light(); onSwipeBack?()
                        }
                    }
            )
        } else if let spot = selected {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(spot.isPendingApproval ? "LUGAR POR REVISAR" : "LUGAR EN EL MAPA")
                    .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                if spot.coverUrl != nil {
                    // La tarjeta de Inicio, con su foto: el dueño reconoce su lugar.
                    HomePlaceCard(card: APIPlaceCard(id: spot.id, name: spot.name, destinationId: nil, destinationName: nil,
                                                     lat: spot.lat, lng: spot.lng, distanceMeters: nil,
                                                     coverUrl: spot.coverUrl, coverUrls: nil, coverPhotos: nil,
                                                     coverAuthorName: nil, coverAuthorAvatarUrl: nil,
                                                     category: nil, photoCount: 0, isNew: false, buddyCount: 0, buddies: []),
                                  large: true)
                } else {
                    Text(spot.name).font(BT.title3).foregroundStyle(Color.ink).lineLimit(2)
                }
                if let errorMessage {
                    Text(errorMessage).font(BT.caption1).foregroundStyle(Color.red)
                }
                primaryButton(title: pickTitle, enabled: !isSubmitting, loading: isSubmitting) {
                    dlog("📍 [ElegirLugarMapa] elegir lugar existente \(spot.id.prefix(8))")
                    onPickSpot(spot)
                }
            }
            .panelStyle()
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Mismo diseño en Compartir un lugar y en la ubicación del negocio (Keyla, 25 Nov 2026).
                searchBlock(inline: true).padding(.bottom, Spacing.xs)
                if !newEyebrow.isEmpty {
                    Text(newEyebrow).font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                }
                if suggestMapPlaces && fixedName == nil && !mapPlaces.isEmpty {
                    Text("¿Es uno de estos lugares cercanos?").font(BT.caption1).foregroundStyle(Color.inkMuted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(mapPlaces, id: \.self) { item in
                                let chosen = name == (item.name ?? "")
                                Button { useMapPlace(item) } label: {
                                    Text(item.name ?? "").font(BT.footnote).lineLimit(1)
                                        .padding(.horizontal, Spacing.md).padding(.vertical, 9)
                                        .background(chosen ? Color.brand : Color.sageTint)
                                        .foregroundStyle(chosen ? Color.inkInverse : Color.brand)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
                // Nombre editable, ya con el del negocio (Keyla, 21 Nov 2026).
                TextField(namePlaceholder, text: $name)
                    .font(BT.callout)
                    .padding(.horizontal, Spacing.md).padding(.vertical, 14)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                    .onAppear { if name.isEmpty, let fixedName { name = fixedName } }
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
                    title: proposeTitle,
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
                    if selectedId == nil, let f = pendingSelectId ?? focusSpotId, res.spots.contains(where: { $0.id == f }) { selectedId = f; pendingSelectId = nil }
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

/// Fila de opción de "Añadir lugar" (Lugares que recomiendas). Compartida con
/// las ubicaciones del negocio (Keyla, 21 Nov 2026: reusar esa experiencia).
struct PlaceOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    var isLoading = false
    var body: some View {

        HStack(spacing: Spacing.md) {
            AppIcon(name: icon, size: 18)
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
}


extension APINearbySpot {
    /// Para mostrar un lugar cercano con la tarjeta de Inicio (HomePlaceCard).
    var asPlaceCard: APIPlaceCard {
        APIPlaceCard(id: id, name: name, destinationId: destinationId, destinationName: destination?.name,
                     lat: lat, lng: lng, distanceMeters: distanceMeters,
                     coverUrl: coverUrl, coverUrls: nil, coverPhotos: nil,
                     coverAuthorName: nil, coverAuthorAvatarUrl: nil,
                     category: nil, photoCount: 0, isNew: false, buddyCount: 0, buddies: [],
                     status: status)
    }
}
