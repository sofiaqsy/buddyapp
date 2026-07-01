import SwiftUI

// MARK: – BuddyProfileView

struct ZoneEntry: Identifiable, Hashable {
    let id: String       // UUID del destination o place
    var name: String
    let source: String   // "destination" | "place"
}

struct BuddyProfileView: View {
    let profile: APIBuddyMeProfile
    let destinations: [APIDestination]
    let onUpdated: (APIBuddyMe) -> Void

    @State private var isAvailable: Bool
    @State private var specialties: Set<String>
    @State private var zones: [ZoneEntry]

    @State private var savingAvailability = false
    @State private var savingZones        = false
    @State private var savingSpecs        = false
    @State private var showZonePicker     = false
    @State private var placeGuides: [String: APIPlaceGuide] = [:]

    init(profile: APIBuddyMeProfile, destinations: [APIDestination], onUpdated: @escaping (APIBuddyMe) -> Void) {
        self.profile      = profile
        self.destinations = destinations
        self.onUpdated    = onUpdated
        _isAvailable = State(initialValue: profile.isAvailable)
        _specialties = State(initialValue: Set(profile.specialties ?? []))
        // Merge destination_ids + place_ids into unified list (destinations first)
        let destIds  = (profile.activeZoneIds?.isEmpty == false ? profile.activeZoneIds! : (profile.destinationIds ?? []))
        let placeIds = profile.placeIds ?? []
        let destEntries  = destIds.map  { ZoneEntry(id: $0, name: $0, source: "destination") }
        let placeEntries = placeIds.map { ZoneEntry(id: $0, name: $0, source: "place") }
        _zones = State(initialValue: destEntries + placeEntries)
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

    // Nombre del primer lugar resuelto (no UUID) — nil hasta que resolveZoneNames() completa
    private var primaryZoneName: String? {
        guard let first = zones.first, first.name != first.id else { return nil }
        return first.name
    }

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
        .sheet(isPresented: $showZonePicker) {
            PlaceZonePickerSheet { result in
                guard !zones.contains(where: { $0.id == result.id }) else { return }
                withAnimation(.spring(duration: 0.35)) {
                    zones.append(result)
                }
                Task { await saveZones() }
            }
        }
    }

    // MARK: – Estado: Aprobado

    private var approvedView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Bloque de pertenencia / contribución
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if let name = primaryZoneName {
                    Text("Ayuda a viajeros hoy y construye la guía de \(name) para quienes lleguen mañana.")
                        .font(BT.title2).foregroundStyle(Color.teal).lineSpacing(2)
                } else {
                    Text("Ya formas parte\nde la comunidad.")
                        .font(BT.title2).foregroundStyle(Color.teal).lineSpacing(2)
                }
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

            Button {} label: {
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
        let destIds  = zones.filter { $0.source == "destination" }.map { $0.id }
        let placeIds = zones.filter { $0.source == "place" }.map { $0.id }
        print("🤝 [BuddyProfileView] saveZones destIds=\(destIds) placeIds=\(placeIds)")
        do {
            let updated = try await APIClient.shared.updateBuddyMe(
                destinationIds: destIds,
                activeZoneIds:  destIds,
                placeIds:       placeIds
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

    private func loadGuides() async {
        let currentZones = zones
        guard !currentZones.isEmpty else { return }
        print("🗺️ [BuddyProfileView] loadGuides count=\(currentZones.count)")
        await withTaskGroup(of: (String, APIPlaceGuide?).self) { group in
            for zone in currentZones {
                group.addTask {
                    print("🗺️ [BuddyProfileView] loadGuide zone=\(zone.id.prefix(8)) source=\(zone.source)")
                    let guide = try? await APIClient.shared.fetchPlaceGuide(id: zone.id, source: zone.source)
                    if let g = guide {
                        print("🗺️ [BuddyProfileView] guide[\(zone.id.prefix(8))] spots=\(g.spotCount) visits=\(g.visitCount) stickers=\(g.stickerCount)")
                    }
                    return (zone.id, guide)
                }
            }
            for await (zoneId, guide) in group {
                if let g = guide {
                    await MainActor.run { placeGuides[zoneId] = g }
                }
            }
        }
    }
}

// MARK: – PlaceZonePickerSheet

struct PlaceZonePickerSheet: View {
    let onSelected: (ZoneEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query           = ""
    @State private var results:        [APIPlaceResult] = []
    @State private var lastValidResults: [APIPlaceResult] = []
    @State private var isSearching     = false
    @State private var isResolving     = false
    @State private var searchTask:     Task<Void, Never>? = nil

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

                if isSearching && results.isEmpty {
                    Spacer(); ProgressView().tint(Color.inkMuted); Spacer()
                } else if results.isEmpty {
                    Spacer()
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "location.slash")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(Color.inkMuted)
                        Text(query.trimmingCharacters(in: .whitespaces).count < 2
                             ? "Escribe para buscar"
                             : "Sin resultados para \"\(query)\"")
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
            onSelected(ZoneEntry(id: place.id, name: place.title, source: "destination"))
            await MainActor.run { dismiss() }
        case "place":
            onSelected(ZoneEntry(id: place.id, name: place.title, source: "place"))
            await MainActor.run { dismiss() }
        default: // nominatim → resolver a place primero
            guard let lat = place.lat, let lng = place.lng else { return }
            if let resolved = try? await APIClient.shared.resolvePlace(lat: lat, lng: lng) {
                onSelected(ZoneEntry(id: resolved.id, name: place.title, source: "place"))
                await MainActor.run { dismiss() }
            }
        }
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
