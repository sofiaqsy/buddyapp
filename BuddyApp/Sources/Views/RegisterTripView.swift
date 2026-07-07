import SwiftUI

// MARK: – REGISTER TRIP SCREEN

struct RegisterTripView: View {
    var onJourneyCreated: (APIJourney) -> Void = { _ in }

    @EnvironmentObject var routeStore: RouteStore

    @State private var searchText        = ""
    @State private var selectedDest: APIDestination? = nil      // chip popular seleccionado
    @State private var selectedPlace: APIPlaceResult? = nil     // resultado de search seleccionado
    @State private var popularDests: [APIDestination] = []      // carga inicial (chips vacíos)
    @State private var searchResults: [APIPlaceResult] = []     // resultados live del API
    @State private var lastValidResults: [APIPlaceResult] = [] // último batch no vacío
    @State private var isSearching       = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var placeContext: APIPlaceContext? = nil
    @State private var isLoadingContext  = false
    @State private var contextTask: Task<Void, Never>? = nil
    @State private var selectedDate: Date  = Date()
    @State private var quickOption: QuickOption? = .here
    @State private var showDatePicker = false
    @State private var isCreating = false
    @State private var createdJourney: APIJourney? = nil
    @State private var showCreateError = false
    @State private var knowsHowToGet = true
    @State private var hasLodging = true
    @State private var popularDestsLoadFailed = false

    enum QuickOption { case here, today, tomorrow }

    private var showPlanningQuestions: Bool { quickOption != .here }

    private var canCreate: Bool { selectedDest != nil || selectedPlace != nil }

    var body: some View {
        ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        // Eyebrow — refleja si el usuario ya está en destino o planifica
                        Text(quickOption == .here ? "DÓNDE ESTÁS AHORA" : "TU PRÓXIMO TRIP")
                            .font(BT.eyebrow)
                            .tracking(2)
                            .foregroundStyle(Color.inkMuted)
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.lg)
                            .padding(.bottom, Spacing.md)
                            .animation(.none, value: quickOption)

                        // ── Destination ─────────────────────────
                        sectionLabel("¿DÓNDE ESTÁS O A DÓNDE VAS?")

                        // Search field
                        HStack(spacing: Spacing.sm) {
                            if isSearching {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(Color.inkMuted)
                                    .font(.system(size: 15))
                            }
                            TextField("¿A dónde vas?", text: $searchText)
                                .font(BT.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onChange(of: searchText) { _, newValue in
                                    if let sel = selectedDest,  sel.name  != newValue { selectedDest  = nil }
                                    if let sel = selectedPlace, sel.title != newValue { selectedPlace = nil }
                                    triggerSearch(query: newValue)
                                }
                            if !searchText.isEmpty {
                                Button {
                                    searchText       = ""
                                    selectedDest     = nil
                                    selectedPlace    = nil
                                    searchResults    = []
                                    lastValidResults = []
                                    placeContext     = nil
                                    searchTask?.cancel()
                                    contextTask?.cancel()
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

                        // Chips de destinos populares: skeleton → datos o retry
                        if popularDests.isEmpty && searchText.isEmpty {
                            if popularDestsLoadFailed {
                                Button {
                                    popularDestsLoadFailed = false
                                    Task {
                                        do {
                                            popularDests = try await APIClient.shared.fetchDestinations()
                                        } catch {
                                            print("❌ [RegisterTrip] retry fetchDestinations: \(error)")
                                            popularDestsLoadFailed = true
                                        }
                                    }
                                } label: {
                                    Label("Reintentar destinos populares", systemImage: "arrow.clockwise")
                                        .font(BT.caption1)
                                        .foregroundStyle(Color.inkMuted)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)
                            } else {
                                HStack(spacing: 8) {
                                    SkeletonBox(cornerRadius: 20).frame(width: 110, height: 38)
                                    SkeletonBox(cornerRadius: 20).frame(width: 90, height: 38)
                                    SkeletonBox(cornerRadius: 20).frame(width: 120, height: 38)
                                }
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)
                                .skeletonPulse()
                            }
                        }

                        // ── Resultados de búsqueda en vivo ──────────
                        let hasTyped = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
                        let nothingSelected = selectedDest == nil && selectedPlace == nil

                        if hasTyped && nothingSelected {
                            if !isSearching && searchResults.isEmpty {
                                HStack(spacing: Spacing.sm) {
                                    Image(systemName: "mappin.slash")
                                        .foregroundStyle(Color.inkMuted)
                                        .font(.system(size: 15))
                                    Text("Sin resultados para \"\(searchText)\"")
                                        .font(BT.callout)
                                        .foregroundStyle(Color.inkMuted)
                                }
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)
                            } else if !searchResults.isEmpty {
                                VStack(spacing: 0) {
                                    ForEach(Array(searchResults.prefix(8).enumerated()), id: \.element.id) { idx, place in
                                        if idx > 0 { Divider().padding(.horizontal, Spacing.md) }
                                        Button {
                                            Haptic.select()
                                            withAnimation(.spring(response: 0.25)) {
                                                selectedPlace = place
                                                selectedDest  = nil
                                                searchText    = place.title
                                            }
                                            fetchContext(id: place.id, source: place.source)
                                            UIApplication.shared.sendAction(
                                                #selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
                                        } label: {
                                            HStack(spacing: Spacing.sm) {
                                                Image(systemName: "mappin.circle")
                                                    .font(.system(size: 14))
                                                    .foregroundStyle(Color.inkMuted)
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(place.title)
                                                        .font(BT.callout)
                                                        .foregroundStyle(Color.ink)
                                                    if let sub = place.subtitle, !sub.isEmpty {
                                                        Text(sub)
                                                            .font(BT.caption1)
                                                            .foregroundStyle(Color.inkMuted)
                                                    }
                                                }
                                                Spacer()
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, Spacing.md)
                                            .padding(.vertical, 12)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.pressable)
                                    }
                                }
                                .background(Color.surface)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
                                .padding(.horizontal, Spacing.edge)
                            }
                        } else if !hasTyped, !popularDests.isEmpty {
                            // Sin texto → chips de destinos populares
                            Text("POPULARES")
                                .font(BT.eyebrow)
                                .tracking(1.5)
                                .foregroundStyle(Color.inkMuted)
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)
                                .padding(.bottom, Spacing.sm)

                            ChipFlow(items: popularDests, selectedId: selectedDest?.id) { dest in
                                Haptic.select()
                                withAnimation(.spring(response: 0.25)) {
                                    selectedDest  = dest
                                    selectedPlace = nil
                                    searchText    = dest.name
                                }
                                fetchContext(id: dest.id, source: "destination")
                                UIApplication.shared.sendAction(
                                    #selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
                            }
                            .padding(.horizontal, Spacing.edge)
                        }

                        // ── Community context card ───────────────
                        if selectedPlace != nil || selectedDest != nil {
                            PlaceCommunityCard(context: placeContext, isLoading: isLoadingContext)
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.sm)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // ── Arrival ──────────────────────────────
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
                                .datePickerStyle(.compact)
                                .labelsHidden()
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
                            guard canCreate, !isCreating else { return }
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
                        .padding(.bottom, Spacing.xl)
                        .safeAreaPadding(.bottom)
                    }
        }
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                popularDests = try await APIClient.shared.fetchDestinations()
            } catch {
                print("❌ [RegisterTrip] fetchDestinations error: \(error)")
                popularDestsLoadFailed = true
            }
        }
        .alert("No pudimos crear tu trip", isPresented: $showCreateError) {
            Button("Reintentar") { createTrip() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Revisa tu conexión e inténtalo de nuevo.")
        }
    }

    // MARK: – Place context (community card)

    private func fetchContext(id: String, source: String) {
        contextTask?.cancel()
        placeContext     = nil
        isLoadingContext = true
        // Nominatim-only: sin DB → pioneer inmediato, sin llamada al backend
        if source == "nominatim" {
            placeContext     = APIPlaceContext(buddies: 0, totalBuddies: 0, stories: 0, status: "pioneer")
            isLoadingContext = false
            return
        }
        contextTask = Task {
            do {
                let ctx = try await APIClient.shared.fetchPlaceContext(id: id, source: source)
                await MainActor.run { placeContext = ctx; isLoadingContext = false }
            } catch {
                print("❌ [context] id=\(id) error: \(error)")
                await MainActor.run { isLoadingContext = false }
            }
        }
    }

    // MARK: – Search (debounced live search via /search/places)

    private func triggerSearch(query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            searchResults    = []
            lastValidResults = []
            isSearching      = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            do {
                let results = try await APIClient.shared.searchPlaces(query: q)
                await MainActor.run {
                    if results.isEmpty {
                        // Si el servidor devuelve vacío, mantener el último batch útil
                        searchResults = lastValidResults
                    } else {
                        searchResults    = results
                        lastValidResults = results
                    }
                    isSearching = false
                }
            } catch {
                print("❌ [triggerSearch] q=\(q) error: \(error)")
                await MainActor.run { isSearching = false }
            }
        }
    }

    // MARK: – Create trip via buddy-core

    private func createTrip() {
        // Resolver qué enviar al backend según el origen del lugar seleccionado
        var destinationId: String? = selectedDest?.id
        var placeId:       String? = nil
        var osmId:         String? = nil
        var lat:           Double? = nil
        var lng:           Double? = nil

        if let place = selectedPlace {
            switch place.source {
            case "place":       placeId       = place.id
            case "destination": destinationId = destinationId ?? place.id
            default:
                // nominatim: mandar el osmKey para que backend lo resuelva sin reverse geocoding
                lat = place.lat; lng = place.lng
                if place.id.hasPrefix("N") || place.id.hasPrefix("W") || place.id.hasPrefix("R") {
                    osmId = place.id
                }
            }
        }

        guard destinationId != nil || placeId != nil || (lat != nil && lng != nil) else { return }

        isCreating = true
        Task {
            // defer garantiza que isCreating baje aunque el Task sea cancelado o
            // la vista desaparezca antes de que el do/catch complete.
            defer { Task { await MainActor.run { isCreating = false } } }
            do {
                let journey = try await APIClient.shared.createJourney(
                    destinationId: destinationId,
                    placeId:       placeId,
                    osmId:         osmId,
                    lat:           lat,
                    lng:           lng,
                    arrivalAt:     quickOption == .here ? nil : selectedDate,
                    knowsHowToGet: quickOption == .here ? nil : knowsHowToGet,
                    hasLodging:    quickOption == .here ? nil : hasLodging
                )
                await MainActor.run {
                    createdJourney = journey
                    onJourneyCreated(journey)
                }
            } catch {
                print("❌ [createTrip] error: \(error)")
                await MainActor.run { showCreateError = true }
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

    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "EEEE, d 'de' MMMM"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "d MMM"
        return f
    }()

    private func formattedDate(_ date: Date) -> String {
        let s = Self.longDateFormatter.string(from: date)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    private func shortDate(_ date: Date) -> String {
        Self.shortDateFormatter.string(from: date)
    }
}

// MARK: – PLACE COMMUNITY CARD

struct PlaceCommunityCard: View {
    let context: APIPlaceContext?
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading || context == nil {
                // Skeleton mientras carga
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBox(cornerRadius: 6).frame(width: 140, height: 14)
                    SkeletonBox(cornerRadius: 6).frame(maxWidth: .infinity, minHeight: 14)
                    SkeletonBox(cornerRadius: 6).frame(width: 100, height: 11)
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
            } else if let ctx = context {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Estado de comunidad
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(ctx.status))
                            .frame(width: 8, height: 8)
                        Text(statusHeadline(ctx.status))
                            .font(BT.footnoteBold)
                            .foregroundStyle(Color.ink)
                    }

                    Text(statusCopy(ctx.status))
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    // Conteos solo si hay algo que mostrar
                    if ctx.buddies > 0 || ctx.stories > 0 {
                        HStack(spacing: Spacing.md) {
                            if ctx.buddies > 0 {
                                Label("\(ctx.buddies) buddy\(ctx.buddies == 1 ? "" : "s")", systemImage: "person.2")
                                    .font(BT.caption1)
                                    .foregroundStyle(Color.inkMuted)
                            }
                            if ctx.stories > 0 {
                                Label("\(ctx.stories) histori\(ctx.stories == 1 ? "a" : "as")", systemImage: "book")
                                    .font(BT.caption1)
                                    .foregroundStyle(Color.inkMuted)
                            }
                        }
                    }
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusBackgroundColor(ctx.status))
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(statusBorderColor(ctx.status), lineWidth: 1))
            }
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "active":  return Color.teal
        case "growing": return Color.yellow
        default:        return Color.inkMuted
        }
    }

    private func statusBackgroundColor(_ status: String) -> Color {
        switch status {
        case "active":  return Color.teal.opacity(0.06)
        case "growing": return Color.yellow.opacity(0.06)
        default:        return Color.surface
        }
    }

    private func statusBorderColor(_ status: String) -> Color {
        switch status {
        case "active":  return Color.teal.opacity(0.3)
        case "growing": return Color.yellow.opacity(0.3)
        default:        return Color.border
        }
    }

    private func statusHeadline(_ status: String) -> String {
        switch status {
        case "active":  return "Comunidad activa"
        case "growing": return "Comunidad creciendo"
        default:        return "Sé el primero aquí"
        }
    }

    private func statusCopy(_ status: String) -> String {
        switch status {
        case "active":  return "Siempre encontrarás alguien que te ayude."
        case "growing": return "Ya hay personas ayudando en esta zona."
        default:        return "Todavía no hay buddies en este lugar. Puedes crear el primer trip."
        }
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
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
