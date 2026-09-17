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

    @Environment(\.dismiss) private var dismiss

    @State private var user: APIUser? = nil
    @State private var shares: [APIPlaceCard] = []
    @State private var trips: [APIJourney] = []
    @State private var isLoading = true
    @State private var failed = false

    private var displayName: String {
        (user?.fullName ?? previewName ?? "Viajero").capitalized
    }

    var body: some View {
        NavigationStack {
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                        .font(BT.footnoteBold)
                        .foregroundStyle(Color.ink)
                }
            }
            .task { await load() }
        }
    }

    // MARK: – Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Circle().fill(Color.tealDeep).frame(width: 64, height: 64)
                    .overlay {
                        CachedImage(urlString: user?.avatarUrl ?? previewAvatarUrl) { img in
                            img.resizable().scaledToFill().frame(width: 64, height: 64).clipShape(Circle())
                        } placeholder: {
                            Text(String(displayName.prefix(1)).uppercased())
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(BT.title3)
                        .foregroundStyle(Color.ink)
                    if let sub = subtitleLine {
                        Text(sub)
                            .font(BT.footnote)
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                Spacer(minLength: 0)
            }
            if let bio = user?.bio, !bio.isEmpty {
                Text(bio)
                    .font(BT.callout)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.edge)
    }

    /// "Buddy en Villa Rica · 12 apoyos" o, si no es buddy, desde cuándo viaja.
    private var subtitleLine: String? {
        if let bp = user?.buddyProfile {
            var parts: [String] = []
            if let dest = bp.destination?.name { parts.append("Buddy en \(dest)") } else { parts.append("Buddy") }
            if let helps = bp.totalHelps, helps > 0 { parts.append("\(helps) apoyo\(helps == 1 ? "" : "s")") }
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
            Text("LUGARES QUE RECOMIENDA")
                .font(BT.eyebrow)
                .tracking(1.5)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(shares) { place in
                        NearbyPlaceCard(
                            place: place,
                            subtitleOverride: place.photoLabel,
                            onTap: {}
                        )
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }
        }
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text("SUS TRIPS")
                .font(BT.eyebrow)
                .tracking(1.5)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
            ForEach(trips) { trip in
                PublishedTripCard(journey: trip).equatable()
            }
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
        print("👤 [TravelerProfile] id=\(travelerId.prefix(8)) user=\(u != nil) shares=\(s?.count ?? -1) trips=\(t?.items.count ?? -1)")
        user   = u
        shares = s ?? []
        trips  = t?.items ?? []
        failed = (u == nil)
        isLoading = false
    }
}
