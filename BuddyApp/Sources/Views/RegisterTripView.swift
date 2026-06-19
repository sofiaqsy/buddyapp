import SwiftUI

// MARK: – REGISTER TRIP SCREEN

struct RegisterTripView: View {
    var onJourneyCreated: (APIJourney) -> Void = { _ in }

    @EnvironmentObject var routeStore: RouteStore

    @State private var searchText     = ""
    @State private var selectedDest: APIDestination? = nil
    @State private var destinations: [APIDestination] = []
    @State private var selectedDate: Date  = Date()
    @State private var quickOption: QuickOption? = .today
    @State private var showDatePicker = false
    @State private var isCreating = false
    @State private var createdJourney: APIJourney? = nil
    @State private var showCreateError = false
    @State private var knowsHowToGet = true
    @State private var hasLodging = true

    enum QuickOption { case here, today, tomorrow }

    private var showPlanningQuestions: Bool { quickOption != .here }

    private var visibleChips: [APIDestination] {
        if searchText.isEmpty { return Array(destinations.prefix(5)) }
        return destinations.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.city.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var canCreate: Bool { selectedDest != nil }

    var body: some View {
        ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        // Eyebrow
                        Text("TU PRÓXIMO TRIP")
                            .font(BT.eyebrow)
                            .tracking(2)
                            .foregroundStyle(Color.inkMuted)
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.lg)
                            .padding(.bottom, Spacing.md)

                        // ── Destination ─────────────────────────
                        sectionLabel("¿A DÓNDE LLEGAS?")

                        // Search field
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Color.inkMuted)
                                .font(.system(size: 15))
                            TextField("Buscar destino…", text: $searchText)
                                .font(BT.callout)
                                .onChange(of: searchText) { _, _ in
                                    // Si el texto ya no coincide con el destino elegido, la selección expira
                                    if let sel = selectedDest, sel.name != searchText {
                                        selectedDest = nil
                                    }
                                }
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                    selectedDest = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Color.inkMuted)
                                        .font(.system(size: 17))
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 14)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                        .padding(.horizontal, Spacing.edge)

                        // Skeleton de chips mientras llegan los destinos
                        if destinations.isEmpty && searchText.isEmpty {
                            HStack(spacing: 8) {
                                SkeletonBox(cornerRadius: 20).frame(width: 110, height: 38)
                                SkeletonBox(cornerRadius: 20).frame(width: 90, height: 38)
                                SkeletonBox(cornerRadius: 20).frame(width: 120, height: 38)
                            }
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.lg)
                        }

                        // Chips — 5 populares o resultados filtrados
                        if !visibleChips.isEmpty {
                            Text(searchText.isEmpty ? "POPULARES" : "RESULTADOS")
                                .font(BT.eyebrow)
                                .tracking(1.5)
                                .foregroundStyle(Color.inkMuted)
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)
                                .padding(.bottom, Spacing.sm)

                            ChipFlow(items: visibleChips, selectedId: selectedDest?.id) { dest in
                                Haptic.select()
                                withAnimation(.spring(response: 0.25)) {
                                    selectedDest = dest
                                    searchText = dest.name
                                }
                            }
                            .padding(.horizontal, Spacing.edge)
                        }

                        // ── Arrival ──────────────────────────────
                        // Opciones rápidas primero: la mayoría llega hoy o mañana
                        sectionLabel("¿CUÁNDO LLEGAS?")
                            .padding(.top, Spacing.xl)

                        HStack(spacing: Spacing.sm) {
                            QuickOptionCard(icon: "mappin.circle",  title: "Ya estoy\naquí",  subtitle: "",        isSelected: quickOption == .here) {
                                quickOption = .here
                                selectedDate = Date()
                                withAnimation { showDatePicker = false }
                            }
                            QuickOptionCard(icon: "sun.horizon",    title: "Hoy",              subtitle: shortDate(Date()),  isSelected: quickOption == .today) {
                                quickOption = .today
                                selectedDate = Date()
                                withAnimation { showDatePicker = false }
                            }
                            QuickOptionCard(icon: "moon.stars",     title: "Mañana",           subtitle: shortDate(tomorrow), isSelected: quickOption == .tomorrow) {
                                quickOption = .tomorrow
                                selectedDate = tomorrow
                                withAnimation { showDatePicker = false }
                            }
                        }
                        .padding(.horizontal, Spacing.edge)

                        // Fecha específica — camino alternativo
                        Button {
                            Haptic.light()
                            withAnimation { showDatePicker.toggle() }
                        } label: {
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(quickOption == nil ? Color.teal : Color.inkMuted)
                                    .font(.system(size: 15))
                                Text(quickOption == nil ? formattedDate(selectedDate) : "O elige otra fecha")
                                    .font(BT.callout)
                                    .foregroundStyle(quickOption == nil ? Color.ink : Color.inkMuted)
                                Spacer()
                                Image(systemName: showDatePicker ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.inkMuted)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, 14)
                            .background(Color.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(
                                quickOption == nil ? Color.teal : Color.border,
                                lineWidth: quickOption == nil ? 1.5 : 1
                            ))
                        }
                        .buttonStyle(.pressable)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.sm)

                        if showDatePicker {
                            DatePicker("", selection: $selectedDate, in: Date()..., displayedComponents: .date)
                                .datePickerStyle(.graphical)
                                .tint(Color.teal)
                                .padding(.horizontal, Spacing.edge)
                                .onChange(of: selectedDate) { _, _ in quickOption = nil }
                        }

                        // ── Planning questions ───────────────────────
                        if showPlanningQuestions {
                            sectionLabel("¿YA LO TIENES RESUELTO?")
                                .padding(.top, Spacing.md)

                            VStack(spacing: Spacing.sm) {
                                PlanningToggleCard(
                                    icon: "bus.fill",
                                    title: "Cómo llegar",
                                    subtitle: "Bus, vuelo, ruta",
                                    isOn: $knowsHowToGet
                                )
                                PlanningToggleCard(
                                    icon: "house.fill",
                                    title: "Dónde hospedarte",
                                    subtitle: "Hotel, hostal, casa",
                                    isOn: $hasLodging
                                )
                            }
                            .padding(.horizontal, Spacing.edge)
                        }

                        // ── CTA al final del scroll ─────────────────
                        Button {
                            Haptic.medium()
                            createTrip()
                        } label: {
                            HStack(spacing: 8) {
                                if isCreating {
                                    ProgressView().tint(Color.inkInverse).scaleEffect(0.8)
                                } else {
                                    Text("Crear trip")
                                        .font(BT.footnoteBold)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 13, weight: .bold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(canCreate ? Color.ink : Color.inkMuted.opacity(0.25))
                            .foregroundStyle(canCreate ? Color.inkInverse : Color.inkMuted)
                            .clipShape(Capsule())
                        }
                        .disabled(!canCreate || isCreating)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.lg)
                        .padding(.bottom, 90)
                    }
        }
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            destinations = (try? await APIClient.shared.fetchDestinations()) ?? []
        }
        .alert("No pudimos crear tu trip", isPresented: $showCreateError) {
            Button("Reintentar") { createTrip() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Revisa tu conexión e inténtalo de nuevo.")
        }
    }

    // MARK: – Create trip via buddy-core

    private func createTrip() {
        guard let dest = selectedDest,
              let userId = AuthService.shared.userId else { return }
        isCreating = true
        Task {
            do {
                let journey = try await APIClient.shared.createJourney(
                    userId: userId,
                    destinationId: dest.id,
                    title: nil,
                    arrivalAt: quickOption == .here ? nil : selectedDate,
                    knowsHowToGet: knowsHowToGet,
                    hasLodging: hasLodging
                )
                await MainActor.run {
                    createdJourney = journey
                    onJourneyCreated(journey)
                    isCreating = false
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    showCreateError = true
                }
            }
        }
    }

    // MARK: – Helpers

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(BT.eyebrow)
            .tracking(1.5)
            .foregroundStyle(Color.ink)
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, Spacing.sm)
    }

    private var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "EEEE, d 'de' MMMM"
        let s = f.string(from: date)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "d MMM"
        return f.string(from: date)
        }
}

// MARK: – CHIP FLOW (wrapping layout)

struct ChipFlow: View {
    let items: [APIDestination]
    let selectedId: String?
    let onSelect: (APIDestination) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items) { dest in
                DestinationChip(
                    name: dest.name,
                    isSelected: selectedId == dest.id,
                    onTap: { onSelect(dest) }
                )
            }
        }
    }
}

// MARK: – FLOW LAYOUT (self-sizing wrapping container)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(proposal.width ?? 0, 1)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxY: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxY = y + rowHeight
        }
        return CGSize(width: width, height: max(maxY, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard bounds.width > 0 else { return }
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}

// MARK: – DESTINATION CHIP

struct DestinationChip: View {
    let name: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "mappin.circle")
                    .font(.system(size: 12))
                Text(name)
                    .font(BT.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(isSelected ? Color.teal.opacity(0.10) : Color.surface)
            .foregroundStyle(isSelected ? Color.teal : Color.ink)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(
                isSelected ? Color.teal : Color.border,
                lineWidth: isSelected ? 1.5 : 1
            ))
        }
        .buttonStyle(.pressable)
    }
}

// MARK: – PLANNING TOGGLE CARD

struct PlanningToggleCard: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isOn ? Color.teal : Color.inkMuted)
                .frame(width: 32)

            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BT.footnoteBold)
                        .foregroundStyle(Color.ink)
                    Text(subtitle)
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            .tint(Color.teal)
            .onChange(of: isOn) { _, _ in Haptic.select() }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 14)
        .background(isOn ? Color.teal.opacity(0.06) : Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(
            isOn ? Color.teal.opacity(0.4) : Color.border, lineWidth: 1
        ))
    }
}

// MARK: – QUICK OPTION CARD

struct QuickOptionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: { Haptic.select(); onTap() }) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(isSelected ? Color.teal : Color.inkMuted)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2, reservesSpace: true)
                Text(subtitle.isEmpty ? " " : subtitle)
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(isSelected ? Color.teal.opacity(0.07) : Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(
                isSelected ? Color.teal : Color.border,
                lineWidth: isSelected ? 1.5 : 1
            ))
        }
        .buttonStyle(.pressable)
    }
}
