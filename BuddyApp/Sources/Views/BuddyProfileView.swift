import SwiftUI
import MapKit

// MARK: – BuddyProfileView

// Represents a specific place the buddy knows well (for guides, spots, etc.)
struct ZoneEntry: Identifiable, Hashable {
    let id: String
    var name: String
    let source: String   // "place"
}

struct BuddyProfileView: View {
    let profile: APIBuddyMeProfile
    let destinations: [APIDestination]
    let onUpdated: (APIBuddyMe) -> Void

    @State private var isAvailable:      Bool
    @State private var specialties:      Set<String>
    @State private var selectedCoverage: BuddyCoverageInput?  // ciudad de cobertura del buddy
    @State private var zones:            [ZoneEntry]           // lugares específicos (place)

    @State private var savingAvailability = false
    @State private var savingZones        = false
    @State private var savingSpecs        = false
    @State private var showZonePicker     = false
    @State private var showReapplyAlert   = false
    @State private var placeGuides: [String: APIPlaceGuide] = [:]
    @State private var guideMapZone: ZoneEntry? = nil
    @State private var guidesLoadedAt: Date? = nil          // TTL cache

    init(profile: APIBuddyMeProfile, destinations: [APIDestination], onUpdated: @escaping (APIBuddyMe) -> Void) {
        self.profile      = profile
        self.destinations = destinations
        self.onUpdated    = onUpdated
        _isAvailable = State(initialValue: profile.isAvailable)
        _specialties = State(initialValue: Set(profile.specialties ?? []))

        // Cobertura: buscar el primer destination en el catálogo local
        let firstDestId = profile.activeZoneIds?.first ?? profile.destinationIds?.first
        let coverageDest = firstDestId.flatMap { id in destinations.first(where: { $0.id == id }) }
        _selectedCoverage = State(initialValue: coverageDest.map { BuddyCoverageInput(from: $0) })

        // Zonas: solo places (spots específicos del buddy)
        let placeEntries = (profile.placeIds ?? []).map { ZoneEntry(id: $0, name: $0, source: "place") }
        _zones = State(initialValue: placeEntries)
    }

    // MARK: – Options

    private static let categoryOptions: [(key: String, label: String)] = [
        ("transport",     "Cómo llegar"),
        ("food",          "Comer"),
        ("translation",   "Traducir"),
        ("activities",    "Qué hacer"),
        ("accommodation", "Alojamiento"),
        ("emergency",     "Seguridad"),
    ]

    // MARK: – Preview contextual por zona

    private func previewText(forZone zone: ZoneEntry) -> String? {
        let cats = specialties.compactMap { key in
            BuddyProfileView.categoryOptions.first(where: { $0.key == key })?.label
        }.sorted()
        guard !cats.isEmpty, zone.name != zone.id else { return nil }

        let catsStr: String
        if cats.count == 1 { catsStr = cats[0].lowercased() }
        else if cats.count == 2 { catsStr = "\(cats[0].lowercased()) y \(cats[1].lowercased())" }
        else {
            let first = cats.prefix(2).map { $0.lowercased() }.joined(separator: ", ")
            catsStr = "\(first) +\(cats.count - 2)"
        }
        return "Los viajeros en \(zone.name) que busquen ayuda con \(catsStr) podrán encontrarte."
    }

    private var status: String { profile.verificationStatus ?? "" }

// MARK: – Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                switch status {
                case "approved": approvedView
                case "pending":  pendingView
                default:         rejectedView
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color.canvas)
        .navigationTitle("Tu perfil de Buddy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { resolveZoneNames() }
        .task(id: zones.map(\.id).joined()) { await loadGuides() }
        .fullScreenCover(item: $guideMapZone, onDismiss: { Task { await loadGuides(force: true) } }) { zone in
            if let g = placeGuides[zone.id], let lat = g.lat, let lng = g.lng {
                BuddyGuideMapSheet(
                    zoneId:   zone.id,
                    source:   zone.source,
                    spots:    g.spots ?? [],
                    center:   .init(latitude: lat, longitude: lng),
                    zoneName: zone.name,
                    destId:   g.destId
                )
            }
        }
        .sheet(isPresented: $showZonePicker) {
            PlaceZonePickerSheet(
                onCoverageSelected: { coverage in
                    selectedCoverage = coverage
                    Task { await saveZones() }
                },
                onPlaceSelected: { place in
                    guard !zones.contains(where: { $0.id == place.id }) else { return }
                    withAnimation(.spring(duration: 0.35)) { zones.append(place) }
                    Task { await saveZones() }
                }
            )
        }
    }

    // MARK: – Estado: Aprobado

    private var approvedView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Bloque de pertenencia / contribución
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Ayuda a viajeros hoy y construye la guía para quienes lleguen mañana.")
                    .font(BT.title2).foregroundStyle(Color.teal).lineSpacing(2)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.teal.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.lg)

            // Toggle disponibilidad
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Disponible ahora")
                        .font(BT.callout).foregroundStyle(Color.ink)
                    Text(isAvailable ? "Los viajeros pueden contactarte" : "No recibirás solicitudes")
                        .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        .animation(.easeInOut, value: isAvailable)
                }
                Spacer()
                if savingAvailability {
                    ProgressView().controlSize(.small).tint(Color.teal)
                } else {
                    Toggle("", isOn: $isAvailable)
                        .labelsHidden().tint(Color.teal)
                        .onChange(of: isAvailable) { _, v in Task { await saveAvailability(v) } }
                }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.md)

            Divider().padding(.horizontal, Spacing.edge)

            // Una card por lugar
            ForEach(zones) { zone in
                zoneCard(zone: zone)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)
            }

            // Botón agregar ciudad
            addZoneButton
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.sm)

            if (profile.totalHelps ?? 0) > 0 {
                let n = profile.totalHelps!
                Text(n == 1 ? "1 viajero acompañado" : "\(n) viajeros acompañados")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.xl)
            }
        }
    }

    // MARK: – Estado: Pendiente

    private var pendingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Tu solicitud\nestá en camino.")
                    .font(BT.title2).foregroundStyle(Color.brandDeep).lineSpacing(2)
                Text("Estamos revisando tu perfil. Mientras tanto puedes preparar dónde y cómo quieres ayudar.")
                    .font(BT.callout).foregroundStyle(Color.brand).lineSpacing(2)
            }
            .padding(Spacing.md).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canvas).clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, Spacing.edge).padding(.top, Spacing.lg)

            ForEach(zones) { zone in
                zoneCard(zone: zone)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)
            }

            addZoneButton
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.sm)
        }
    }

    // MARK: – Estado: No aprobado

    private var rejectedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Por ahora no podemos\nincluirte en la comunidad.")
                    .font(BT.title2).foregroundStyle(Color.ink).lineSpacing(2)
                Text("A veces necesitamos más tiempo para revisar los perfiles. Puedes volver a solicitarlo cuando quieras.")
                    .font(BT.callout).foregroundStyle(Color.inkMuted).lineSpacing(2)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.lg)

            Button { showReapplyAlert = true } label: {
                Text("Volver a solicitar")
                    .font(BT.callout).foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .alert("Gracias por tu interés", isPresented: $showReapplyAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Pronto habilitaremos la opción para volver a solicitar. Si tienes preguntas, escríbenos.")
            }

            Text("Si tienes preguntas, escríbenos. Respondemos a cada solicitud con atención.")
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)
        }
    }

    // MARK: – Card por zona (especialidades + guía del lugar)

    private func zoneCard(zone: ZoneEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header: nombre del lugar + botón eliminar
            HStack(spacing: 8) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(Color.teal)
                Text(zone.name)
                    .font(BT.callout).fontWeight(.semibold).foregroundStyle(Color.ink)
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.3)) { zones.removeAll { $0.id == zone.id } }
                    Haptic.select()
                    Task { await saveZones() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.inkMuted)
                        .padding(6)
                        .background(Color.surface).clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            Divider().padding(.horizontal, 14)

            // Especialidades: cómo ayudo en este lugar
            VStack(alignment: .leading, spacing: 10) {
                Text("Cómo puedo ayudar")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
                FlowLayout(spacing: 6) {
                    ForEach(BuddyProfileView.categoryOptions, id: \.key) { opt in
                        let on = specialties.contains(opt.key)
                        Button {
                            Haptic.select()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if on { specialties.remove(opt.key) } else { specialties.insert(opt.key) }
                            }
                            Task { await saveSpecialties() }
                        } label: {
                            Text(opt.label)
                                .font(BT.caption1).fontWeight(on ? .semibold : .regular)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(on ? Color.teal.opacity(0.12) : Color.surface)
                                .foregroundStyle(on ? Color.teal : Color.inkMuted)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(on ? Color.teal : Color.border, lineWidth: on ? 1 : 0.5))
                                .animation(.easeInOut(duration: 0.18), value: on)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            // Guía del lugar
            Text("Guía del lugar")
                .font(BT.eyebrow).tracking(1.2).foregroundStyle(Color.inkMuted)
                .padding(.horizontal, 14).padding(.top, 10)

            let guide = placeGuides[zone.id]
            if let g = guide {
                if g.spotCount == 0 {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ningún lugar todavía.")
                            .font(BT.callout).foregroundStyle(Color.ink)
                        Text("Comienza agregando el primero.")
                            .font(BT.caption1).foregroundStyle(Color.inkMuted)
                    }
                    .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
                } else {
                    HStack(spacing: 20) {
                        GuideStatView(value: g.spotCount,
                                      label: g.spotCount == 1 ? "lugar" : "lugares")
                        if g.visitCount > 0 {
                            GuideStatView(value: g.visitCount,
                                          label: g.visitCount == 1 ? "visita" : "visitas")
                        }
                        if g.stickerCount > 0 {
                            GuideStatView(value: g.stickerCount,
                                          label: g.stickerCount == 1 ? "sticker" : "stickers")
                        }
                    }
                    .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
                }
            } else {
                ProgressView().controlSize(.small).tint(Color.inkMuted)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            }

            // Mapa del lugar — tappable: abre BuddyGuideMapSheet (componente del viajero)
            if let lat = guide?.lat, let lng = guide?.lng {
                ZoneMapView(
                    center: .init(latitude: lat, longitude: lng),
                    spots:  guide?.spots ?? []
                )
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ink.opacity(0.75))
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { Haptic.select(); guideMapZone = zone }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }

            // Preview contextual por zona
            if let preview = previewText(forZone: zone) {
                Divider().padding(.horizontal, 14)
                Text(preview)
                    .font(BT.caption1).foregroundStyle(Color.inkMuted).lineSpacing(2)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity).animation(.easeInOut(duration: 0.25), value: preview)
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
    }

    // MARK: – Botón agregar ciudad

    private var addZoneButton: some View {
        Button { showZonePicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14, weight: .semibold))
                Text(zones.isEmpty ? "Agregar mi primera ciudad" : "Agregar ciudad")
                    .font(BT.callout).fontWeight(.medium)
            }
            .foregroundStyle(Color.teal)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Color.teal.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.teal.opacity(0.3),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .buttonStyle(.plain)
    }


    // MARK: – Actions

    private func resolveZoneNames() {
        for i in zones.indices {
            let entry = zones[i]
            if entry.source == "destination" {
                if let local = destinations.first(where: { $0.id == entry.id }) {
                    zones[i].name = local.name; continue
                }
                if let dest = profile.destination, dest.id == entry.id {
                    zones[i].name = dest.name; continue
                }
                Task {
                    if let dest = try? await APIClient.shared.fetchDestination(id: entry.id) {
                        await MainActor.run {
                            if let j = zones.firstIndex(where: { $0.id == entry.id }) {
                                zones[j].name = dest.name
                            }
                        }
                    }
                }
            } else {
                // place source — lookup via /places/geo/:id
                Task {
                    if let place = try? await APIClient.shared.fetchGeoPlace(id: entry.id) {
                        await MainActor.run {
                            if let j = zones.firstIndex(where: { $0.id == entry.id }) {
                                zones[j].name = place.name
                            }
                        }
                    }
                }
            }
        }
    }

    private func saveAvailability(_ available: Bool) async {
        savingAvailability = true
        defer { savingAvailability = false }
        do {
            let updated = try await APIClient.shared.updateBuddyMe(isAvailable: available)
            onUpdated(updated)
            Haptic.success()
        } catch {
            await MainActor.run { isAvailable = !available }
            Haptic.error()
        }
    }

    private func saveZones() async {
        savingZones = true
        defer { savingZones = false }
        let placeIds = zones.map(\.id)
        print("🤝 [BuddyProfileView] saveZones coverage=\(selectedCoverage?.city ?? "nil") placeIds=\(placeIds)")
        do {
            // SIEMPRE enviar place_ids, incluso vacío: [] significa "sin zonas"
            // y el backend limpia la cobertura completa. Mandar nil al vaciar
            // dejaba la última zona pegada (el PATCH llegaba sin el campo).
            let updated = try await APIClient.shared.updateBuddyMe(
                coverage: selectedCoverage,
                placeIds: placeIds
            )
            onUpdated(updated)
        } catch {
            Haptic.error()
        }
    }

    private func saveSpecialties() async {
        savingSpecs = true
        defer { savingSpecs = false }
        do {
            let updated = try await APIClient.shared.updateBuddyMe(specialties: Array(specialties))
            onUpdated(updated)
        } catch {
            Haptic.error()
        }
    }

    private func loadGuides(force: Bool = false) async {
        // TTL de 60 s — evita N×3 requests por usuario al navegar entre vistas
        if !force, let loaded = guidesLoadedAt, Date().timeIntervalSince(loaded) < 60 { return }
        let currentZones = zones
        guard !currentZones.isEmpty else { return }
        print("🗺️ [BuddyProfileView] loadGuides count=\(currentZones.count) force=\(force)")
        await withTaskGroup(of: (String, APIPlaceGuide?).self) { group in
            for zone in currentZones {
                group.addTask {
                    print("🗺️ [BuddyProfileView] loadGuide zone=\(zone.id.prefix(8)) source=\(zone.source)")
                    let guide = try? await APIClient.shared.fetchPlaceGuide(id: zone.id, source: zone.source)
                    if let g = guide {
                        print("🗺️ [BuddyProfileView] guide[\(zone.id.prefix(8))] spots=\(g.spotCount)(preview=\(g.spots?.count ?? 0) hasMore=\(g.hasMoreSpots ?? false)) visits=\(g.visitCount)")
                    }
                    return (zone.id, guide)
                }
            }
            for await (zoneId, guide) in group {
                if let g = guide { await MainActor.run { placeGuides[zoneId] = g } }
            }
        }
        await MainActor.run { guidesLoadedAt = Date() }
    }
}

// MARK: – PlaceZonePickerSheet

struct PlaceZonePickerSheet: View {
    let onCoverageSelected: (BuddyCoverageInput) -> Void
    let onPlaceSelected:    (ZoneEntry) -> Void

    @EnvironmentObject private var locationService: LocationService
    @Environment(\.dismiss) private var dismiss
    @State private var query           = ""
    @State private var results:        [APIPlaceResult] = []
    @State private var lastValidResults: [APIPlaceResult] = []
    @State private var isSearching     = false
    @State private var isResolving     = false
    @State private var searchTask:     Task<Void, Never>? = nil

    // Sugerencia por GPS — el lugar donde el buddy está parado ahora mismo,
    // para no obligarlo a escribir su propia ciudad al configurar cobertura.
    @State private var suggestion:          APIPlaceResult? = nil
    @State private var isLoadingSuggestion  = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color.inkMuted).font(.system(size: 15))
                    TextField("Buscar ciudad o país…", text: $query)
                        .font(BT.callout).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button {
                            query            = ""
                            results          = []
                            lastValidResults = []
                            searchTask?.cancel()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.inkMuted)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md).padding(.bottom, Spacing.sm)

                Divider()

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Sin búsqueda activa: ofrecer el lugar actual como atajo.
                    VStack(spacing: 0) {
                        if let suggestion {
                            Text("SUGERIDO CERCA DE TI")
                                .font(BT.eyebrow).tracking(1.2).foregroundStyle(Color.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.edge).padding(.top, Spacing.md).padding(.bottom, Spacing.xs)
                            suggestionRow(suggestion)
                            Spacer()
                        } else if isLoadingSuggestion {
                            Spacer(); ProgressView().tint(Color.inkMuted); Spacer()
                        } else {
                            Spacer()
                            VStack(spacing: Spacing.sm) {
                                Image(systemName: "location.slash")
                                    .font(.system(size: 30, weight: .light)).foregroundStyle(Color.inkMuted)
                                Text("Escribe para buscar")
                                    .font(BT.callout).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                            }
                            Spacer()
                        }
                    }
                } else if isSearching && results.isEmpty {
                    Spacer(); ProgressView().tint(Color.inkMuted); Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(Color.inkMuted)
                        Text("Sin resultados para \"\(query)\"")
                            .font(BT.callout).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                    }
                    Spacer()
                } else {
                    List(results) { place in
                        Button {
                            guard !isResolving else { return }
                            Task { await pick(place) }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.teal.opacity(0.1)).frame(width: 36, height: 36)
                                    Image(systemName: place.source == "destination" ? "location.circle.fill" : "globe")
                                        .font(.system(size: 16)).foregroundStyle(Color.teal)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.title).font(BT.callout).foregroundStyle(Color.ink)
                                    if let sub = place.subtitle {
                                        Text(sub).font(BT.caption1).foregroundStyle(Color.inkMuted)
                                    }
                                }
                                Spacer()
                                if isResolving { ProgressView().controlSize(.small) }
                            }
                            .padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Elegir ciudad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
            }
        }
        .onChange(of: query) { _, _ in triggerSearch(query: query) }
        .task { await loadSuggestion() }
    }

    // Misma fila visual que un resultado de búsqueda, pero con ícono de
    // ubicación actual y subtítulo fijo (en vez de país/tipo de lugar).
    private func suggestionRow(_ place: APIPlaceResult) -> some View {
        Button {
            guard !isResolving else { return }
            Task { await pick(place) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.teal.opacity(0.1)).frame(width: 36, height: 36)
                    Image(systemName: "location.fill")
                        .font(.system(size: 15)).foregroundStyle(Color.teal)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.title).font(BT.callout).foregroundStyle(Color.ink)
                    Text("Tu ubicación actual").font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
                Spacer()
                if isResolving { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 6).padding(.horizontal, Spacing.edge).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Resuelve el GPS del buddy a un lugar sugerido — SIEMPRE vía /places/resolve
    /// (el mismo flujo pioneer que ensureActiveTripForGPS), nunca /location/resolve:
    /// un destino curado (source "destination") solo declara cobertura de ciudad
    /// en el servidor sin aparecer como zona visible, así que la sugerencia
    /// "no hacía nada" al tocarla. /places/resolve siempre da un lugar real
    /// (auto-creado si hace falta) que SÍ se agrega como card visible.
    private func loadSuggestion() async {
        guard let loc = locationService.userLocation else { return }
        await MainActor.run { isLoadingSuggestion = true }
        defer { Task { await MainActor.run { isLoadingSuggestion = false } } }

        let lat = loc.coordinate.latitude, lng = loc.coordinate.longitude
        if let place = try? await APIClient.shared.resolvePlace(lat: lat, lng: lng) {
            await MainActor.run {
                suggestion = APIPlaceResult(
                    id: place.id, source: "place",
                    title: place.name, subtitle: nil, lat: lat, lng: lng
                )
            }
        }
    }

    private func triggerSearch(query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            results          = []
            lastValidResults = []
            isSearching      = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            do {
                let items = try await APIClient.shared.searchPlaces(query: q)
                await MainActor.run {
                    if items.isEmpty {
                        results = lastValidResults
                    } else {
                        results          = items
                        lastValidResults = items
                    }
                    isSearching = false
                }
            } catch {
                print("❌ [PlaceZonePickerSheet] q=\(q) error: \(error)")
                await MainActor.run { isSearching = false }
            }
        }
    }

    private func pick(_ place: APIPlaceResult) async {
        await MainActor.run { isResolving = true }
        defer { Task { await MainActor.run { isResolving = false } } }
        switch place.source {
        case "destination":
            // Ciudad del catálogo: enviamos el destinationId para que el backend haga lookup directo
            let coverage = BuddyCoverageInput(
                destinationId: place.id,
                city:          place.title,
                countryCode:   place.subtitle ?? "",
                latitude:      place.lat,
                longitude:     place.lng
            )
            await MainActor.run { onCoverageSelected(coverage); dismiss() }
        case "place":
            await MainActor.run {
                onPlaceSelected(ZoneEntry(id: place.id, name: place.title, source: "place"))
                dismiss()
            }
        default: // nominatim → resolver a place en DB primero
            guard let lat = place.lat, let lng = place.lng else { return }
            if let resolved = try? await APIClient.shared.resolvePlace(lat: lat, lng: lng) {
                await MainActor.run {
                    onPlaceSelected(ZoneEntry(id: resolved.id, name: place.title, source: "place"))
                    dismiss()
                }
            }
        }
    }
}

// MARK: – BuddyGuideMapSheet
// Mapa completo de la guía del buddy — misma estructura que DescubrirView.
// Soporta: borrar, editar nombre, mover ubicación y agregar nuevos spots.
// Long press en edit mode activa el crosshair para agregar un nuevo spot.

struct BuddyGuideMapSheet: View {
    let zoneId: String
    let source: String
    let center: CLLocationCoordinate2D
    let zoneName: String
    let destId: String?   // para crear nuevos spots (nil si no hay destination vinculada)
    var travelerMode: Bool = false  // oculta Editar; muestra CTA de primer spot al viajero

    @State private var localSpots: [APIPlaceGuideSpot]
    @State private var camera: MapCameraPosition = .automatic
    @State private var selectedPlace: Place? = nil
    @State private var sheetDetent: PresentationDetent = .fraction(0.42)
    @State private var editMode = false
    @State private var deletingId: String? = nil
    @State private var editingSpot: APIPlaceGuideSpot? = nil
    @State private var movingSpotId: String? = nil
    @State private var addingNew = false
    @State private var addFormReady = false
    @State private var spotName = ""
    @State private var spotPlaceType = "landmark"
    @State private var isSaving = false
    @State private var saveError: String? = nil
    @State private var currentCenter: CLLocationCoordinate2D
    @State private var editSheetRefreshId = 0

    @Environment(\.dismiss) private var dismiss

    init(zoneId: String, source: String, spots: [APIPlaceGuideSpot], center: CLLocationCoordinate2D, zoneName: String, destId: String?, travelerMode: Bool = false) {
        self.zoneId       = zoneId
        self.source       = source
        _localSpots       = State(initialValue: spots.sorted { $0.name < $1.name })
        self.center       = center
        self.zoneName     = zoneName
        self.destId       = destId
        self.travelerMode = travelerMode
        _currentCenter    = State(initialValue: center)
    }

    private var places: [Place] { localSpots.map(\.asPlace) }

    private var controlBottomPadding: CGFloat {
        let h = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                .screen.bounds.height ?? 844
        return sheetDetent == .medium ? h * 0.5 + Spacing.xl : h * 0.42 + Spacing.xl
    }

    private var inCrosshair: Bool { (addingNew && !addFormReady) || movingSpotId != nil }
    private var showEditForm: Bool { editingSpot != nil && movingSpotId == nil }
    private var showAddForm:  Bool { addingNew && addFormReady }

    private func cancelSubMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            addingNew    = false
            addFormReady = false
            movingSpotId = nil
            editingSpot  = nil
            saveError    = nil
        }
    }

    var body: some View {
        ZStack {
            Map(position: $camera) {
                ForEach(places) { place in
                    Annotation("", coordinate: place.coordinate) {
                        PlacePin(place: place, isSelected: selectedPlace?.id == place.id)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .onTapGesture {
                                guard !editMode || inCrosshair else { return }
                                Haptic.select()
                                withAnimation(.spring(response: 0.3)) {
                                    selectedPlace = selectedPlace?.id == place.id ? nil : place
                                }
                            }
                            .accessibilityLabel(place.name)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { EmptyView() }
            .ignoresSafeArea()
            .onMapCameraChange { ctx in currentCenter = ctx.region.center }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                    guard editMode, destId != nil, !inCrosshair, editingSpot == nil else { return }
                    Haptic.medium()
                    withAnimation { addingNew = true; addFormReady = false }
                }
            )
            .onTapGesture {
                guard selectedPlace != nil, !editMode else { return }
                withAnimation(.easeOut(duration: 0.2)) { selectedPlace = nil }
            }

            // Crosshair — marca la posición exacta del nuevo spot o la nueva ubicación
            if inCrosshair {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.teal)
                    .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                    .allowsHitTesting(false)
            }

            // Barra superior — usa windowSafeAreaTop (UIKit) para colocar botones
            // justo debajo del Dynamic Island o notch, sin importar el dispositivo
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    if inCrosshair || showEditForm || showAddForm {
                        Button { cancelSubMode() } label: {
                            Text("Cancelar")
                                .font(BT.callout).fontWeight(.medium)
                                .foregroundStyle(Color.ink)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    } else if !travelerMode {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { editMode.toggle() }
                            if !editMode { selectedPlace = nil }
                            Haptic.select()
                        } label: {
                            Text(editMode ? "Listo" : "Editar")
                                .font(BT.callout).fontWeight(.medium)
                                .foregroundStyle(editMode ? Color.teal : Color.ink)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }

            // Fit-all (solo en browse)
            if !editMode && !inCrosshair {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        MapControlButton(symbol: "arrow.up.left.and.arrow.down.right") {
                            Haptic.light(); fitAll()
                        }
                        .padding(.trailing, Spacing.md)
                        .padding(.bottom, controlBottomPadding)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sheetDetent)
                    }
                }
            }
        }
        .sheet(isPresented: .constant(true)) {
            Group {
                if showAddForm {
                    SpotFormContent(
                        title: "Nuevo lugar",
                        name: $spotName,
                        placeType: $spotPlaceType,
                        isSaving: isSaving,
                        saveError: saveError,
                        onSave:   { Task { await commitCreateSpot() } },
                        onCancel: { withAnimation { addFormReady = false } }
                    )
                } else if showEditForm, let spot = editingSpot {
                    SpotFormContent(
                        title: "Editar lugar",
                        name: $spotName,
                        placeType: $spotPlaceType,
                        isSaving: isSaving,
                        saveError: saveError,
                        onSave:   { Task { await commitUpdateSpot(spot) } },
                        onCancel: { withAnimation { editingSpot = nil } },
                        onMove: {
                            withAnimation {
                                movingSpotId = spot.id
                                editingSpot  = nil
                            }
                        },
                        onDelete: { Task { await deleteSpot(id: spot.id) } }
                    )
                } else if inCrosshair {
                    SpotPositionPicker(
                        isForNew: addingNew,
                        isSaving: isSaving,
                        onConfirm: { Task { await confirmPosition() } },
                        onCancel: cancelSubMode
                    )
                } else if editMode {
                    BuddyEditSheet(
                        zoneId:     zoneId,
                        source:     source,
                        destId:     destId,
                        deletingId: $deletingId,
                        onDelete:   deleteSpot,
                        onEdit: { spot in
                            editingSpot   = spot
                            spotName      = spot.name
                            spotPlaceType = "landmark"
                            saveError     = nil
                        },
                        onAddNew: {
                            addingNew    = true
                            addFormReady = false
                            saveError    = nil
                        }
                    )
                    .id(editSheetRefreshId)
                } else {
                    PlacesSheet(
                        places: places,
                        selectedPlace: $selectedPlace,
                        onSelectPlace: { place in
                            Haptic.medium()
                            withAnimation(.spring(response: 0.4)) {
                                camera = .region(MKCoordinateRegion(
                                    center: place.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                                ))
                                selectedPlace = place
                            }
                        },
                        onAddFirstSpot: travelerMode ? {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                editMode = false
                            }
                            dismiss()
                        } : nil
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: editMode)
            .presentationDetents([.fraction(0.42), .medium, .large], selection: $sheetDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationCornerRadius(Radius.xl)
            .interactiveDismissDisabled()
        }
        .onAppear { fitAll() }
    }

    private func fitAll() {
        guard !places.isEmpty else {
            camera = .region(MKCoordinateRegion(center: center, latitudinalMeters: 6000, longitudinalMeters: 6000))
            return
        }
        let coords = places.map(\.coordinate)
        let minLat = coords.map(\.latitude).min()!
        let maxLat = coords.map(\.latitude).max()!
        let minLon = coords.map(\.longitude).min()!
        let maxLon = coords.map(\.longitude).max()!
        withAnimation(.easeInOut(duration: 0.7)) {
            camera = .region(MKCoordinateRegion(
                center: .init(latitude: (minLat + maxLat) / 2 - (maxLat - minLat) * 0.15,
                              longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(
                    latitudeDelta:  max(maxLat - minLat, 0.006) * 2.6,
                    longitudeDelta: max(maxLon - minLon, 0.006) * 2.6
                )
            ))
        }
    }

    private func confirmPosition() async {
        if addingNew {
            await MainActor.run {
                withAnimation { addFormReady = true }
                spotName      = ""
                spotPlaceType = "landmark"
                saveError     = nil
            }
        } else if let movId = movingSpotId {
            await MainActor.run { isSaving = true; saveError = nil }
            let lat = currentCenter.latitude
            let lng = currentCenter.longitude
            do {
                let updated = try await APIClient.shared.updateSpot(id: movId, lat: lat, lng: lng)
                print("✏️ [BuddyGuideMapSheet] moved spot=\(movId.prefix(8)) lat=\(lat) lng=\(lng)")
                await MainActor.run {
                    if let i = localSpots.firstIndex(where: { $0.id == movId }) {
                        let old = localSpots[i]
                        localSpots[i] = APIPlaceGuideSpot(id: updated.id, name: updated.name,
                                                          lat: updated.lat, lng: updated.lng,
                                                          coverUrl: updated.coverUrl ?? old.coverUrl)
                    }
                    movingSpotId       = nil
                    isSaving           = false
                    editSheetRefreshId += 1
                }
                Haptic.success()
            } catch {
                print("❌ [BuddyGuideMapSheet] move error=\(error)")
                await MainActor.run { isSaving = false; saveError = "Error al mover el lugar" }
                Haptic.error()
            }
        }
    }

    private func commitCreateSpot() async {
        guard let destId else { return }
        let name = spotName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await MainActor.run { isSaving = true; saveError = nil }
        do {
            let created = try await APIClient.shared.createSpot(
                destinationId: destId,
                name: name,
                lat: currentCenter.latitude,
                lng: currentCenter.longitude,
                placeType: spotPlaceType
            )
            print("➕ [BuddyGuideMapSheet] created spot=\(created.id.prefix(8)) name=\"\(created.name)\"")
            await MainActor.run {
                let newSpot = APIPlaceGuideSpot(id: created.id, name: created.name,
                                                lat: created.lat, lng: created.lng, coverUrl: created.coverUrl)
                let idx = localSpots.firstIndex(where: { $0.name > created.name }) ?? localSpots.endIndex
                withAnimation { localSpots.insert(newSpot, at: idx) }
                addingNew          = false
                addFormReady       = false
                isSaving           = false
                editMode           = false
                editSheetRefreshId += 1
            }
            Haptic.success()
        } catch {
            print("❌ [BuddyGuideMapSheet] create error=\(error)")
            await MainActor.run { isSaving = false; saveError = "Error al guardar el lugar" }
            Haptic.error()
        }
    }

    private func commitUpdateSpot(_ spot: APIPlaceGuideSpot) async {
        let name = spotName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await MainActor.run { isSaving = true; saveError = nil }
        do {
            let updated = try await APIClient.shared.updateSpot(id: spot.id, name: name, placeType: spotPlaceType)
            print("✏️ [BuddyGuideMapSheet] updated spot=\(spot.id.prefix(8)) name=\"\(updated.name)\"")
            await MainActor.run {
                if let i = localSpots.firstIndex(where: { $0.id == spot.id }) {
                    localSpots[i] = APIPlaceGuideSpot(id: updated.id, name: updated.name,
                                                      lat: updated.lat, lng: updated.lng,
                                                      coverUrl: updated.coverUrl ?? spot.coverUrl)
                }
                localSpots.sort { $0.name < $1.name }
                editingSpot        = nil
                isSaving           = false
                editSheetRefreshId += 1
            }
            Haptic.success()
        } catch {
            print("❌ [BuddyGuideMapSheet] update error=\(error)")
            await MainActor.run { isSaving = false; saveError = "Error al actualizar el lugar" }
            Haptic.error()
        }
    }

    private func deleteSpot(id: String) async {
        await MainActor.run { deletingId = id }
        defer { Task { await MainActor.run { deletingId = nil } } }
        do {
            try await APIClient.shared.deleteSpot(id: id)
            print("🗑️ [BuddyGuideMapSheet] deleted spot=\(id.prefix(8))")
            await MainActor.run {
                withAnimation { localSpots.removeAll { $0.id == id } }
                editingSpot = nil
                if localSpots.isEmpty { editMode = false }
            }
        } catch {
            print("❌ [BuddyGuideMapSheet] delete spot=\(id.prefix(8)) error=\(error)")
            Haptic.error()
        }
    }
}

// MARK: – BuddyEditSheet
// Lista paginada de spots (cursor-based). Carga 20 por página y añade más al llegar al final.
// Desacoplada del guide preview: fetch independiente de /places/:id/guide/spots.

private struct BuddyEditSheet: View {
    let zoneId: String
    let source: String
    let destId: String?
    @Binding var deletingId: String?
    let onDelete: (String) async -> Void
    let onEdit: (APIPlaceGuideSpot) -> Void
    let onAddNew: () -> Void

    @State private var spots:      [APIPlaceGuideSpot] = []
    @State private var nextCursor: String?              = nil
    @State private var hasMore     = false
    @State private var isLoading   = false
    @State private var loadError   = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Editar guía")
                        .font(BT.displayMedium).foregroundStyle(Color.ink)
                    Spacer()
                    if destId != nil {
                        Button { onAddNew() } label: {
                            Label("Agregar", systemImage: "plus.circle.fill")
                                .font(BT.footnote).fontWeight(.medium)
                                .foregroundStyle(Color.teal)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.teal.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md).padding(.bottom, Spacing.sm)

                if isLoading && spots.isEmpty {
                    ProgressView().tint(Color.inkMuted)
                        .frame(maxWidth: .infinity).padding(.top, Spacing.xl)
                } else if spots.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No hay lugares en esta guía todavía.")
                            .font(BT.callout).foregroundStyle(Color.ink)
                        if destId != nil {
                            Text("Toca \"Agregar\" o mantén presionado el mapa.")
                                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                    }
                    .padding(.horizontal, Spacing.edge).padding(.top, Spacing.md)
                } else {
                    VStack(spacing: 0) {
                        ForEach(spots) { spot in
                            SpotEditRow(spot: spot, deletingId: $deletingId, onDelete: onDelete, onEdit: onEdit)
                                .onAppear {
                                    if spot.id == spots.dropLast().last?.id && hasMore && !isLoading {
                                        Task { await loadMore() }
                                    }
                                }
                            if spot.id != spots.last?.id {
                                Divider().padding(.leading, Spacing.edge + 48 + 12)
                            }
                        }

                        if isLoading {
                            ProgressView().controlSize(.small).tint(Color.inkMuted)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                        } else if hasMore {
                            Button { Task { await loadMore() } } label: {
                                Text("Cargar más")
                                    .font(BT.callout).foregroundStyle(Color.teal)
                                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
                    .padding(.horizontal, Spacing.edge)
                }

                if loadError {
                    Text("Error cargando lugares. Toca para reintentar.")
                        .font(BT.caption1).foregroundStyle(Color.errorRed)
                        .padding(.horizontal, Spacing.edge).padding(.top, Spacing.sm)
                        .onTapGesture { Task { await loadFirst() } }
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .background(Color.canvas)
        .task { await loadFirst() }
    }

    private func loadFirst() async {
        guard !isLoading else { return }
        isLoading  = true
        loadError  = false
        nextCursor = nil
        defer { isLoading = false }
        do {
            let page = try await APIClient.shared.fetchGuideSpots(id: zoneId, source: source, cursor: nil)
            print("📋 [BuddyEditSheet] first page spots=\(page.spots.count) hasMore=\(page.hasMore)")
            spots      = page.spots
            nextCursor = page.nextCursor
            hasMore    = page.hasMore
        } catch {
            print("❌ [BuddyEditSheet] loadFirst error=\(error)")
            loadError = true
        }
    }

    private func loadMore() async {
        guard !isLoading, hasMore, let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await APIClient.shared.fetchGuideSpots(id: zoneId, source: source, cursor: cursor)
            print("📋 [BuddyEditSheet] next page spots=\(page.spots.count) hasMore=\(page.hasMore)")
            spots     += page.spots
            nextCursor = page.nextCursor
            hasMore    = page.hasMore
        } catch {
            print("❌ [BuddyEditSheet] loadMore error=\(error)")
        }
    }
}

private struct SpotEditRow: View {
    let spot: APIPlaceGuideSpot
    @Binding var deletingId: String?
    let onDelete: (String) async -> Void
    let onEdit: (APIPlaceGuideSpot) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let url = spot.coverUrl {
                CachedImage(urlString: url) { img in img.resizable().scaledToFill() }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.1))
                    Image(systemName: "mappin.circle.fill").font(.system(size: 20)).foregroundStyle(Color.teal)
                }
                .frame(width: 48, height: 48)
            }
            Text(spot.name).font(BT.callout).foregroundStyle(Color.ink).lineLimit(2)
            Spacer()
            if deletingId == spot.id {
                ProgressView().controlSize(.small).tint(Color.inkMuted).frame(width: 64)
            } else {
                HStack(spacing: 4) {
                    Button { Haptic.select(); onEdit(spot) } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 14)).foregroundStyle(Color.ink)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Editar \(spot.name)")
                    Button { Haptic.medium(); Task { await onDelete(spot.id) } } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14)).foregroundStyle(Color.errorRed)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Eliminar \(spot.name)")
                }
            }
        }
        .padding(.horizontal, Spacing.edge).padding(.vertical, 12)
    }
}

// MARK: – SpotFormContent
// Formulario reutilizable para crear o editar un spot.
// onMove y onDelete son opcionales (solo en modo edición de spot existente).

private struct SpotFormContent: View {
    let title: String
    @Binding var name: String
    @Binding var placeType: String
    let isSaving: Bool
    let saveError: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    var onMove: (() -> Void)? = nil
    var onDelete: (() async -> Void)? = nil

    private let categories: [(key: String, label: String, icon: String)] = [
        ("landmark", "Cultura",    "building.columns"),
        ("cafe",     "Café",       "cup.and.saucer"),
        ("park",     "Naturaleza", "leaf"),
        ("market",   "Mercado",    "basket"),
        ("activity", "Actividad",  "figure.walk"),
        ("hidden",   "Secreto",    "sparkles"),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(title)
                    .font(BT.displayMedium).foregroundStyle(Color.ink)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Nombre")
                        .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, Spacing.edge)
                    TextField("ej. Catarata El León", text: $name)
                        .font(BT.callout)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
                        .padding(.horizontal, Spacing.edge)
                        .submitLabel(.done)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Categoría")
                        .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, Spacing.edge)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories, id: \.key) { cat in
                                let selected = placeType == cat.key
                                Button { placeType = cat.key } label: {
                                    Label(cat.label, systemImage: cat.icon)
                                        .font(BT.footnote)
                                        .foregroundStyle(selected ? Color.inkInverse : Color.ink)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(selected ? Color.teal : Color.surface)
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(selected ? Color.clear : Color.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .animation(.easeInOut(duration: 0.15), value: selected)
                            }
                        }
                        .padding(.horizontal, Spacing.edge)
                    }
                }

                if let err = saveError {
                    Text(err)
                        .font(BT.caption1).foregroundStyle(Color.errorRed)
                        .padding(.horizontal, Spacing.edge)
                }

                if let onMove = onMove {
                    Button { onMove() } label: {
                        Label("Mover en el mapa", systemImage: "map.fill")
                            .font(BT.callout)
                            .foregroundStyle(Color.teal)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(Color.teal.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.teal.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.edge)
                }

                Button { onSave() } label: {
                    Group {
                        if isSaving {
                            ProgressView().tint(Color.inkInverse)
                        } else {
                            Text("Guardar")
                                .font(BT.callout).fontWeight(.medium).foregroundStyle(Color.inkInverse)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .background(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving ? Color.border : Color.teal)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                .padding(.horizontal, Spacing.edge)
                .buttonStyle(.plain)

                if let onDelete = onDelete {
                    Button { Haptic.medium(); Task { await onDelete() } } label: {
                        Text("Eliminar lugar")
                            .font(BT.callout).foregroundStyle(Color.errorRed)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.edge)
                }
            }
            .padding(.bottom, Spacing.xl)
        }
        .background(Color.canvas)
    }
}

// MARK: – SpotPositionPicker
// Hoja inferior durante el modo crosshair: el buddy arrastra el mapa y confirma la posición.

private struct SpotPositionPicker: View {
    let isForNew: Bool
    let isSaving: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: 4) {
                Text(isForNew ? "Nuevo lugar" : "Mover lugar")
                    .font(BT.displayMedium).foregroundStyle(Color.ink)
                Text("Arrastra el mapa para posicionar el marcador")
                    .font(BT.callout).foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Spacing.md)
            .padding(.horizontal, Spacing.edge)

            Button { onConfirm() } label: {
                Group {
                    if isSaving {
                        ProgressView().tint(Color.inkInverse)
                    } else {
                        Text(isForNew ? "Confirmar posición" : "Mover aquí")
                            .font(BT.callout).fontWeight(.medium).foregroundStyle(Color.inkInverse)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .background(isSaving ? Color.border : Color.teal)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(isSaving)
            .padding(.horizontal, Spacing.edge)
            .buttonStyle(.plain)

            Button { onCancel() } label: {
                Text("Cancelar")
                    .font(BT.callout).foregroundStyle(Color.inkMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.edge)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.xl)
        .background(Color.canvas)
    }
}

// MARK: – GuideStatView

private struct GuideStatView: View {
    let value: Int
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(BT.title3).fontWeight(.semibold).foregroundStyle(Color.ink)
            Text(label)
                .font(BT.caption1).foregroundStyle(Color.inkMuted)
        }
    }
}

// MARK: – ZoneMapView

private struct ZoneMapView: View {
    let center: CLLocationCoordinate2D
    let spots: [APIPlaceGuideSpot]

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: center,
            latitudinalMeters: 6000,
            longitudinalMeters: 6000
        ))) {
            ForEach(spots, id: \.id) { spot in
                Marker(spot.name, coordinate: .init(latitude: spot.lat, longitude: spot.lng))
                    .tint(Color.teal)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .disabled(true)
    }
}

// MARK: – ZonePill

private struct ZonePill: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(BT.caption1).fontWeight(.medium)
                .foregroundStyle(Color.teal)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.teal.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Color.teal.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.teal.opacity(0.3), lineWidth: 0.5))
        .transition(.scale.combined(with: .opacity))
    }
}
