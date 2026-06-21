import SwiftUI

// MARK: – BuddyProfileView
// Pantalla dedicada a la configuración e identidad del buddy.
// Se navega desde YoView mediante NavigationLink (patrón Settings.app).

struct BuddyProfileView: View {
    let profile: APIBuddyMeProfile
    let destinations: [APIDestination]
    let onUpdated: (APIBuddyMe) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isAvailable: Bool
    @State private var specialties: Set<String>
    @State private var savingAvailability = false
    @State private var savingSpecs        = false
    @State private var savingZone         = false
    @State private var showZonePicker     = false
    @State private var showSpecPicker     = false
    @State private var selectedZoneName: String? = nil

    init(profile: APIBuddyMeProfile, destinations: [APIDestination], onUpdated: @escaping (APIBuddyMe) -> Void) {
        self.profile      = profile
        self.destinations = destinations
        self.onUpdated    = onUpdated
        _isAvailable = State(initialValue: profile.isAvailable)
        _specialties = State(initialValue: Set(profile.specialties ?? []))
    }

    // MARK: – Computed

    private static let specialtyOptions: [(key: String, label: String)] = [
        ("transport",      "Cómo llegar"),
        ("food",           "Comer"),
        ("translation",    "Traducir"),
        ("activities",     "Qué hacer"),
        ("accommodation",  "Alojamiento"),
        ("emergency",      "Seguridad"),
    ]

    private var verificationColor: Color {
        switch profile.verificationStatus {
        case "approved": return Color.teal
        case "pending":  return Color(hex: "#D97706")
        default:         return Color.inkMuted
        }
    }
    private var verificationLabel: String {
        switch profile.verificationStatus {
        case "approved": return "Buddy verificado"
        case "pending":  return "Verificación pendiente"
        default:         return "En revisión"
        }
    }
    private var verificationIcon: String {
        switch profile.verificationStatus {
        case "approved": return "checkmark.seal.fill"
        case "pending":  return "hourglass"
        default:         return "shield"
        }
    }

    private var specialtiesSublabel: String {
        let labels = specialties.compactMap { key in
            BuddyProfileView.specialtyOptions.first(where: { $0.key == key })?.label
        }.sorted()
        if labels.isEmpty { return "Sin categorías aún" }
        if labels.count <= 2 { return labels.joined(separator: " · ") }
        return labels.prefix(2).joined(separator: " · ") + " +\(labels.count - 2)"
    }

    private var selectedZoneId: String? {
        profile.activeZoneIds?.first ?? profile.destinationIds?.first
    }

    // MARK: – Body

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Estado ──────────────────────────────────────
                statusHeader
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.lg)

                // ── Sección CONFIGURACIÓN ───────────────────────
                sectionLabel("CONFIGURACIÓN")
                    .padding(.top, Spacing.xl)

                configList
                    .padding(.horizontal, Spacing.edge)

                // ── Sección ESTADÍSTICAS ────────────────────────
                if profile.verificationStatus == "approved" {
                    sectionLabel("ESTADÍSTICAS")
                        .padding(.top, Spacing.xl)

                    statsGrid
                        .padding(.horizontal, Spacing.edge)
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color.canvas)
        .navigationTitle("Perfil de Buddy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { resolveZoneName() }
        .sheet(isPresented: $showZonePicker) {
            DestinationPickerSheet(selectedId: selectedZoneId) { picked in
                Task { await saveZone(picked.id, name: picked.name) }
            }
        }
        .sheet(isPresented: $showSpecPicker) {
            SpecialtyPickerSheet(selected: $specialties) {
                Task { await saveSpecialties() }
            }
        }
    }

    // MARK: – Subviews

    private var statusHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(verificationColor.opacity(0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: verificationIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(verificationColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(verificationLabel)
                    .font(BT.headline)
                    .foregroundStyle(verificationColor)
                if profile.verificationStatus == "pending" {
                    Text("Revisaremos tu perfil pronto")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                } else {
                    let n = profile.totalHelps ?? 0
                    Text(n == 1 ? "1 ayuda realizada" : "\(n) ayudas realizadas")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            Spacer()
        }
        .padding(Spacing.md)
        .background(verificationColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var configList: some View {
        VStack(spacing: 0) {
            // Toggle disponibilidad
            HStack(spacing: 14) {
                rowIcon("location.circle.fill", color: Color.teal)
                Text("Disponible ahora")
                    .font(BT.callout)
                    .foregroundStyle(Color.ink)
                Spacer()
                if savingAvailability {
                    ProgressView().controlSize(.small).tint(Color.teal)
                } else {
                    Toggle("", isOn: $isAvailable)
                        .labelsHidden()
                        .tint(Color.teal)
                        .onChange(of: isAvailable) { _, newVal in
                            Task { await saveAvailability(newVal) }
                        }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16).inset(by: 0))

            Divider().padding(.leading, 58)

            // Mi zona
            Button { showZonePicker = true } label: {
                HStack(spacing: 14) {
                    rowIcon("map.fill", color: Color.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mi zona")
                            .font(BT.callout)
                            .foregroundStyle(Color.ink)
                        Text(selectedZoneName ?? "Elegir dónde operas")
                            .font(BT.caption1)
                            .foregroundStyle(selectedZoneName == nil ? Color.inkMuted.opacity(0.6) : Color.inkMuted)
                    }
                    Spacer()
                    if savingZone {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.inkMuted.opacity(0.4))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
                .background(Color.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(savingZone)

            Divider().padding(.leading, 58)

            // En qué ayudo
            Button { showSpecPicker = true } label: {
                HStack(spacing: 14) {
                    rowIcon("sparkles", color: Color.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("En qué ayudo")
                            .font(BT.callout)
                            .foregroundStyle(Color.ink)
                        Text(specialtiesSublabel)
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    if savingSpecs {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.inkMuted.opacity(0.4))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
                .background(Color.surface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(savingSpecs)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
    }

    private var statsGrid: some View {
        HStack(spacing: 10) {
            statCard(
                value: "\(profile.totalHelps ?? 0)",
                label: "Ayudas",
                icon: "hands.sparkles.fill"
            )
            statCard(
                value: "\(profile.offersAccepted ?? 0)",
                label: "Aceptadas",
                icon: "checkmark.circle.fill"
            )
        }
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(BT.title3)
                    .foregroundStyle(Color.ink)
                Text(label)
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.border, lineWidth: 1))
    }

    @ViewBuilder
    private func rowIcon(_ name: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.1))
                .frame(width: 32, height: 32)
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(BT.eyebrow).tracking(1.5)
            .foregroundStyle(Color.inkMuted)
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, Spacing.sm)
    }

    // MARK: – Actions

    private func resolveZoneName() {
        guard let id = selectedZoneId else { return }
        if let local = destinations.first(where: { $0.id == id }) { selectedZoneName = local.name; return }
        if let dest = profile.destination, dest.id == id { selectedZoneName = dest.name; return }
        Task {
            let dest = try? await APIClient.shared.fetchDestination(id: id)
            await MainActor.run { selectedZoneName = dest?.name }
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

    private func saveZone(_ id: String, name: String) async {
        savingZone = true
        selectedZoneName = name
        defer { savingZone = false }
        do {
            let updated = try await APIClient.shared.updateBuddyMe(destinationIds: [id], activeZoneIds: [id])
            onUpdated(updated)
            Haptic.success()
        } catch {
            resolveZoneName()
            Haptic.error()
        }
    }
}

// MARK: – SpecialtyPickerSheet

private struct SpecialtyPickerSheet: View {
    @Binding var selected: Set<String>
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private static let options: [(key: String, label: String, icon: String)] = [
        ("transport",     "Cómo llegar",  "car.fill"),
        ("food",          "Comer",         "fork.knife"),
        ("translation",   "Traducir",      "text.bubble.fill"),
        ("activities",    "Qué hacer",     "figure.walk"),
        ("accommodation", "Alojamiento",   "bed.double.fill"),
        ("emergency",     "Seguridad",     "shield.fill"),
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(SpecialtyPickerSheet.options, id: \.key) { opt in
                    Button {
                        Haptic.select()
                        if selected.contains(opt.key) { selected.remove(opt.key) }
                        else { selected.insert(opt.key) }
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.teal.opacity(0.1))
                                    .frame(width: 32, height: 32)
                                Image(systemName: opt.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.teal)
                            }
                            Text(opt.label)
                                .font(BT.callout)
                                .foregroundStyle(Color.ink)
                            Spacer()
                            if selected.contains(opt.key) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.teal)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("En qué ayudo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .tint(Color.teal)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
