import SwiftUI

// MARK: – Perfil público de otro viajero
//
// Solo lectura: quién es, qué lugares recomienda y qué trips publicó. El id
// llega de `journey.users?.id` (traveler.id — ver migración 014, que lo añadió
// justo para poder abrir este perfil). Si un autor viene sin id, el nombre no
// se puede tocar: no hay perfil que abrir.

struct TravelerProfileView: View {
    let travelerId: String
    /// Nombre y avatar que ya tenía la tarjeta: evitan una cabecera vacía
    /// mientras carga el perfil.
    var previewName: String? = nil
    var previewAvatarUrl: String? = nil

    @State private var user: APIUser? = nil
    @State private var shares: [APIPlaceCard] = []
    @State private var trips: [APIJourney] = []
    @State private var isLoading = true
    @State private var tripsHasMore = false
    @State private var tripsCursor: String? = nil
    @State private var isLoadingMore = false
    @State private var selectedStory: APIJourney? = nil
    @State private var openPlace: APIPlaceCard? = nil
    @State private var failed = false

    private var displayName: String {
        (user?.fullName ?? previewName ?? "Viajero").capitalized
    }

    // Se abre con push dentro de la navegación de la pestaña (pantalla
    // completa, botón atrás del sistema), no como hoja (Keyla, 19 Nov 2026).
    var body: some View {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    header
                    if isLoading {
                        skeleton
                    } else if failed && user == nil {
                        retry
                    } else {
                        if !shares.isEmpty { sharesSection }
                        if !trips.isEmpty { tripsSection }
                        if shares.isEmpty && trips.isEmpty { emptyState }
                    }
                    Spacer().frame(height: 40)
                }
                .padding(.top, Spacing.lg)
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $selectedStory) { StoryViewerSheet(journey: $0) }
            .navigationDestination(item: $openPlace) { PlaceGuideMapSheet(place: $0) }
            .task { await load() }
    }

    // MARK: – Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                // Igual que la cabecera de Yo: avatar grande sobre pale sage.
                Circle().fill(Color.paleSage).frame(width: 88, height: 88)
                    .overlay {
                        CachedImage(urlString: user?.avatarUrl ?? previewAvatarUrl) { img in
                            img.resizable().scaledToFill().frame(width: 88, height: 88).clipShape(Circle())
                        } placeholder: {
                            Text(String(displayName.prefix(1)).uppercased())
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(Color.brand)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(.title2).weight(.bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if let sub = subtitleLine {
                        Text(sub)
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            if let bio = user?.bio, !bio.isEmpty {
                // Texto plano, sin tarjeta: en un perfil ajeno no se edita y una
                // tarjeta blanca parecía un campo para escribir (Keyla, 20 Nov 2026).
                Text(bio)
                    .font(BT.callout)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.edge)
    }

    /// "Buddy en Villa Rica · 12 apoyos" o, si no es buddy, desde cuándo viaja.
    private var subtitleLine: String? {
        if let bp = user?.buddyProfile {
            var parts: [String] = []
            if let dest = bp.destination?.name { parts.append("Buddy en \(dest)") } else { parts.append("Buddy") }
            return parts.joined(separator: " · ")
        }
        if let since = user?.memberSince {
            let f = DateFormatter()
            f.locale = Locale(identifier: "es_PE")
            f.dateFormat = "MMMM yyyy"
            return "Viaja con Buddy desde \(f.string(from: since))"
        }
        return nil
    }

    // MARK: – Secciones

    private var sharesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionTitle(title: "Lugares que recomienda", count: shares.count)
                .padding(.horizontal, Spacing.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shares) { place in
                        // Abre el lugar, como en Yo.
                        NearbyPlaceCard(place: place, subtitleOverride: place.photoLabel) {
                            openPlace = place
                        }
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }
        }
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            SectionTitle(title: "Trips publicados", count: trips.count)
                .padding(.horizontal, Spacing.edge)
            ProfileTripsGrid(journeys: trips, hasMore: tripsHasMore,
                             onTap: { selectedStory = $0 },
                             onReachEnd: { Task { await loadMoreTrips() } })
        }
    }

    private var emptyState: some View {
        Text("Todavía no ha publicado nada.")
            .font(BT.callout)
            .foregroundStyle(Color.inkMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SkeletonBox(cornerRadius: 12).frame(height: 158)
                .padding(.horizontal, Spacing.edge)
            SkeletonBox(cornerRadius: 16).frame(height: 240)
                .padding(.horizontal, Spacing.edge)
        }
        .skeletonPulse()
    }

    private var retry: some View {
        VStack(spacing: Spacing.sm) {
            Text("No pudimos cargar este perfil")
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
            Button {
                Task { await load() }
            } label: {
                Text("Reintentar")
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 10)
                    .background(Color.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }

    // MARK: – Carga
    //
    // Las tres llamadas son independientes: van juntas para que el perfil abra
    // en el tiempo de la más lenta, no en la suma.

    private func load() async {
        isLoading = true
        failed = false
        async let userTask   = try? APIClient.shared.fetchUser(id: travelerId)
        async let sharesTask = try? APIClient.shared.fetchUserShares(travelerId: travelerId)
        async let tripsTask  = try? APIClient.shared.fetchUserTrips(travelerId: travelerId)
        let (u, s, t) = await (userTask, sharesTask, tripsTask)
        dlog("👤 [TravelerProfile] id=\(travelerId.prefix(8)) user=\(u != nil) shares=\(s?.count ?? -1) trips=\(t?.items.count ?? -1)")
        user   = u
        shares = s ?? []
        trips  = t?.items ?? []
        tripsHasMore = t?.hasMore ?? false
        tripsCursor = t?.nextCursor
        failed = (u == nil)
        isLoading = false
    }

    /// Siguiente página con el cursor del servidor (cuántos trips ya llegaron).
    private func loadMoreTrips() async {
        guard tripsHasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await APIClient.shared.fetchUserTrips(travelerId: travelerId, cursor: tripsCursor) else {
            tripsHasMore = false; return
        }
        let nuevos = page.items.filter { n in !trips.contains { $0.id == n.id } }
        trips += nuevos
        tripsCursor = page.nextCursor
        tripsHasMore = page.hasMore && page.nextCursor != nil && !nuevos.isEmpty
    }
}
