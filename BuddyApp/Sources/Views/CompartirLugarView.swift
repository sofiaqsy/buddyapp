import SwiftUI
import CoreLocation

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

    // Búsqueda (paso "Buscar otro lugar")
    @State private var searchText = ""
    @State private var searchResults: [APIPlaceResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    // Spots curados cercanos (paso "Lugar actual")
    @State private var nearbySpots: [APINearbySpot] = []
    @State private var currentCoords: (lat: Double, lng: Double)?
    @State private var proposedName = ""
    @State private var categories: [APISpotCategory] = []
    @State private var selectedCategoryId: String?
    @State private var isPrefetching = false
    @State private var didPrefetch = false

    enum Step { case choose, search, propose }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .choose:  chooseStep
                case .search:  searchStep
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
            } else {
                // Sin catálogo cerca: nombrarlo es la única vía.
                Button { useCurrentLocation() } label: {
                    optionRow(
                        icon: "location.fill",
                        title: "Lugar actual",
                        subtitle: isPrefetching ? "buscando…" : "nombra dónde estás",
                        isLoading: isSubmitting
                    )
                }
                .buttonStyle(.pressable)
                .disabled(isSubmitting || isPrefetching)
            }

            Button { step = .search } label: {
                optionRow(icon: "magnifyingglass", title: "Buscar otro lugar", subtitle: nil, isLoading: false)
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

            Button { step = .search } label: {
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
        guard !name.isEmpty, let coords = currentCoords, !isSubmitting else { return }
        Haptic.medium()
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                let spot = try await APIClient.shared.proposeSpot(
                    name: name, lat: coords.lat, lng: coords.lng, categoryId: selectedCategoryId
                )
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

    // MARK: – Paso 2: buscar otro lugar

    @ViewBuilder
    private var searchStep: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                if isSearching {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.inkMuted)
                        .font(.system(size: 15))
                }
                TextField("Buscar un lugar", text: $searchText)
                    .font(BT.callout)
                    .onChange(of: searchText) { _, newValue in triggerSearch(query: newValue) }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)

            if let errorMessage {
                Text(errorMessage)
                    .font(BT.caption1)
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.sm)
            }

            List(searchResults) { result in
                Button { submitSearchResult(result) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(BT.body).foregroundStyle(Color.ink)
                        if let subtitle = result.subtitle {
                            Text(subtitle).font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                    }
                }
                .disabled(isSubmitting)
            }
            .listStyle(.plain)
            .overlay {
                if isSubmitting {
                    Color.black.opacity(0.05).ignoresSafeArea()
                    ProgressView()
                }
            }
        }
    }

    private func triggerSearch(query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { isSearching = true }
            let results = (try? await APIClient.shared.searchPlaces(query: trimmed)) ?? []
            guard !Task.isCancelled else { return }
            await MainActor.run { searchResults = results; isSearching = false }
        }
    }

    private func submitSearchResult(_ result: APIPlaceResult) {
        Haptic.medium()
        errorMessage = nil
        switch result.source {
        case "place":
            submit(placeId: result.id)
        case "destination":
            submit(destinationId: result.id)
        default:
            // "nominatim" — resultado crudo sin fila en `place` todavía;
            // createJourney lo resuelve con findOrCreatePlace vía lat/lng,
            // mismo camino que el flujo normal de registrar un trip.
            guard let lat = result.lat, let lng = result.lng else {
                errorMessage = "Ese resultado no tiene coordenadas — prueba con otra búsqueda."
                return
            }
            submit(lat: lat, lng: lng)
        }
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
