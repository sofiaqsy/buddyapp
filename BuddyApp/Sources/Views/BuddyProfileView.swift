import SwiftUI

// MARK: – BuddyProfileView

struct BuddyProfileView: View {
    let profile: APIBuddyMeProfile
    let destinations: [APIDestination]
    let onUpdated: (APIBuddyMe) -> Void

    @State private var isAvailable: Bool
    @State private var specialties: Set<String>
    @State private var zoneIds: [String]           // orden importa para display
    @State private var zoneNames: [String: String] // id → nombre resuelto

    @State private var savingAvailability = false
    @State private var savingZones        = false
    @State private var savingSpecs        = false
    @State private var showZonePicker     = false

    init(profile: APIBuddyMeProfile, destinations: [APIDestination], onUpdated: @escaping (APIBuddyMe) -> Void) {
        self.profile      = profile
        self.destinations = destinations
        self.onUpdated    = onUpdated
        _isAvailable = State(initialValue: profile.isAvailable)
        _specialties = State(initialValue: Set(profile.specialties ?? []))
        let ids = (profile.activeZoneIds?.isEmpty == false)
            ? profile.activeZoneIds!
            : (profile.destinationIds ?? [])
        _zoneIds   = State(initialValue: ids)
        _zoneNames = State(initialValue: [:])
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

    // MARK: – Preview line

    private var previewText: String? {
        let zones = zoneIds.compactMap { zoneNames[$0] }
        let cats  = specialties.compactMap { key in
            BuddyProfileView.categoryOptions.first(where: { $0.key == key })?.label
        }.sorted()

        guard !zones.isEmpty, !cats.isEmpty else { return nil }

        let zonesStr: String
        if zones.count == 1 { zonesStr = zones[0] }
        else { zonesStr = zones.dropLast().joined(separator: ", ") + " y \(zones.last!)" }

        let catsStr: String
        if cats.count == 1 { catsStr = cats[0].lowercased() }
        else if cats.count == 2 { catsStr = "\(cats[0].lowercased()) y \(cats[1].lowercased())" }
        else {
            let first = cats.prefix(2).map { $0.lowercased() }.joined(separator: ", ")
            catsStr = "\(first) +\(cats.count - 2)"
        }

        return "Los viajeros en \(zonesStr) que busquen ayuda con \(catsStr) podrán encontrarte."
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
        .sheet(isPresented: $showZonePicker) {
            DestinationPickerSheet(selectedId: nil) { picked in
                guard !zoneIds.contains(picked.id) else { return }
                withAnimation(.spring(duration: 0.35)) {
                    zoneIds.append(picked.id)
                    zoneNames[picked.id] = picked.name
                }
                Task { await saveZones() }
            }
        }
    }

    // MARK: – Estado: Aprobado

    private var approvedView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Bloque de pertenencia
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Ya formas parte\nde la comunidad.")
                    .font(BT.title2).foregroundStyle(Color.teal)
                    .lineSpacing(2)
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

            presenceCard(isPending: false)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.xl)

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
                    .font(BT.title2)
                    .foregroundStyle(Color.brandDeep)
                    .lineSpacing(2)
                Text("Estamos revisando tu perfil. Mientras tanto puedes preparar dónde y cómo quieres ayudar.")
                    .font(BT.callout)
                    .foregroundStyle(Color.brand)
                    .lineSpacing(2)
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.lg)

            presenceCard(isPending: true)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.xl)
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

    // MARK: – Tarjeta de presencia (compartida entre estados)

    private func presenceCard(isPending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Zonas ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                Text(isPending ? "Prepara tu perfil" : "Así ayudaré a los viajeros")
                    .font(BT.eyebrow).tracking(1.5)
                    .foregroundStyle(Color.inkMuted)

                Text("Dónde estaré")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)

                // Pills de zonas + botón añadir
                FlowLayout(spacing: 6) {
                    ForEach(zoneIds, id: \.self) { id in
                        ZonePill(
                            name: zoneNames[id] ?? id,
                            onRemove: {
                                withAnimation(.spring(duration: 0.3)) {
                                    zoneIds.removeAll { $0 == id }
                                }
                                Haptic.select()
                                Task { await saveZones() }
                            }
                        )
                    }
                    // Botón añadir zona
                    Button {
                        showZonePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text(zoneIds.isEmpty ? "Elegir mi ciudad" : "Agregar")
                                .font(BT.caption1).fontWeight(.medium)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(Color.inkMuted)
                        .background(Color.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            // ── Categorías — toggles inline ────────────────────
            VStack(alignment: .leading, spacing: 10) {
                Text("Cómo puedo ayudar")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)

                FlowLayout(spacing: 6) {
                    ForEach(BuddyProfileView.categoryOptions, id: \.key) { opt in
                        let on = specialties.contains(opt.key)
                        Button {
                            Haptic.select()
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if on { specialties.remove(opt.key) }
                                else  { specialties.insert(opt.key) }
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
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 14)

            // ── Preview line — actualiza en tiempo real ────────
            if let preview = previewText {
                Divider().padding(.horizontal, 14)
                Text(preview)
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
                    .lineSpacing(2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: previewText)
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
    }

    // MARK: – Actions

    private func resolveZoneNames() {
        for id in zoneIds {
            if let local = destinations.first(where: { $0.id == id }) {
                zoneNames[id] = local.name; continue
            }
            if let dest = profile.destination, dest.id == id {
                zoneNames[id] = dest.name; continue
            }
            Task {
                let dest = try? await APIClient.shared.fetchDestination(id: id)
                if let name = dest?.name {
                    await MainActor.run { zoneNames[id] = name }
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
        do {
            let updated = try await APIClient.shared.updateBuddyMe(
                destinationIds: zoneIds,
                activeZoneIds: zoneIds
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
