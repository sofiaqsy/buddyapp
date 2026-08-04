import SwiftUI

// MARK: – Perfil público de otra persona
//
// El mismo perfil del tab Yo, en modo lectura. Deliberadamente la misma
// disposición y los mismos componentes: quien ve el perfil de un buddy tiene que
// reconocer de inmediato que está viendo "lo mismo que tengo yo", porque eso es
// lo que le dice qué puede llegar a construir. Una pantalla distinta rompería
// esa lectura.
//
// Lo que NO aparece es todo lo que es una acción sobre uno mismo: el menú de
// cuenta, editar la bio, cambiar el avatar, "Añadir lugar", el CTA de hacerse
// buddy y la invitación por demanda sin cubrir. Ver el perfil de alguien no
// ofrece nada que hacer sobre él salvo mirar lo que aportó.

struct UserProfileView: View {
    let route: TravelerProfileRoute

    @StateObject private var vm: UserProfileViewModel
    @State private var selectedStory: APIJourney? = nil
    @Environment(\.dismiss) private var dismiss

    init(route: TravelerProfileRoute) {
        self.route = route
        _vm = StateObject(wrappedValue: UserProfileViewModel(travelerId: route.travelerId))
    }

    private var displayName: String {
        vm.user?.fullName ?? route.previewName ?? "Buddy"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Sin antetítulo "PERFIL": la pantalla ya se abrió tocando una
                // cara, así que nadie duda de qué está viendo. Etiquetarlo solo
                // empujaba el nombre hacia abajo.
                Text(displayName)
                    .font(BT.title1)
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)

                profileHeader
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.lg)

                if let bio = vm.user?.bio, !bio.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(bio)
                        .font(BT.callout)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.md)
                }

                if let bp = vm.user?.buddyProfile {
                    buddyCard(bp)
                        .padding(.horizontal, Spacing.edge)
                        .padding(.top, Spacing.xl)
                }

                if !vm.stickers.isEmpty {
                    stickerSection.padding(.top, Spacing.xl)
                }

                if !vm.shares.isEmpty {
                    sharesSection.padding(.top, Spacing.xl)
                }

                if !vm.journeys.isEmpty {
                    tripsSection.padding(.top, Spacing.xl)
                }

                if vm.loadFailed {
                    emptyState("No pudimos cargar este perfil", icon: "wifi.exclamationmark")
                        .padding(.top, Spacing.xxl)
                } else if !vm.isLoadingUser && vm.stickers.isEmpty
                            && vm.shares.isEmpty && vm.journeys.isEmpty {
                    // Un buddy recién aprobado no ha aportado nada todavía. No es
                    // un error ni un vacío que haya que disimular.
                    emptyState("\(displayName.split(separator: " ").first.map(String.init) ?? displayName) todavía no ha compartido nada")
                        .padding(.top, Spacing.xxl)
                }
            }
            .padding(.bottom, Spacing.xl)
            .safeAreaPadding(.bottom)
        }
        .background(Color.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .sheet(item: $selectedStory) { journey in
            StoryViewerSheet(journey: journey)
        }
        .task { await vm.load() }
    }

    // MARK: Cabecera

    /// Avatar + una línea de contexto. Sin PhotosPicker: la foto de otro no se
    /// toca.
    private var profileHeader: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            ZStack {
                Circle().fill(Color.sandLight).frame(width: 88, height: 88)
                // El avatar del listado mientras llega /users/:id: es la misma
                // imagen y ya está en caché, así que la cabecera nunca sale gris.
                CachedImage(urlString: vm.user?.avatarUrl ?? route.previewAvatarUrl) { img in
                    img.resizable().scaledToFill()
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                } placeholder: {
                    Image(systemName: "person.fill")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(Color.sand)
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(metaLine)
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
                if let since = vm.user?.memberSince {
                    Text("Viajando desde \(UserProfileView.memberSince(since))")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: String {
        let trips = vm.journeys.count
        let tripsLabel = trips == 1 ? "1 trip" : "\(trips) trips"
        let stickersLabel = vm.stickers.isEmpty ? nil
            : (vm.stickers.count == 1 ? "1 sticker" : "\(vm.stickers.count) stickers")
        return [tripsLabel, stickersLabel].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Tarjeta de buddy

    /// Quién es como buddy: si está disponible, dónde y a cuánta gente ha
    /// ayudado.
    private func buddyCard(_ bp: APIBuddyProfile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Circle()
                    .fill(bp.isAvailable ? Color.onlineGreen : Color.sand)
                    .frame(width: 7, height: 7)
                Text(bp.isAvailable ? "Buddy disponible" : "Buddy")
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                Spacer()
                if let helps = bp.totalHelps, helps > 0 {
                    Text(helps == 1 ? "1 apoyo" : "\(helps) apoyos")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }

            // TODOS los destinos donde eligió ser buddy, no solo el primero.
            // Sin icono de ubicación: la tarjeta ya dice que habla de un buddy y
            // el pin repetía lo que el propio nombre del sitio ya comunica.
            let cobertura = bp.coverageNames
            if !cobertura.isEmpty {
                Text(cobertura.joined(separator: " · "))
                    .font(BT.caption1)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Sin las especialidades. Este perfil responde "quién es y dónde
            // está", no "qué me puede resolver": lo segundo es cosa del flujo de
            // pedir ayuda, que ya pregunta la intención antes de buscar buddy.
            // Listarlas acá invitaba a elegir persona por su etiqueta, y el
            // emparejamiento no funciona así.
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    // MARK: Secciones

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
            Text("\(count)").font(BT.caption1).foregroundStyle(Color.inkMuted.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, Spacing.edge)
    }

    private var stickerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("STICKERS", count: vm.stickers.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(vm.stickers, id: \.id) { s in
                        VStack(spacing: 6) {
                            ZStack {
                                Circle().fill(Color.sandLight).frame(width: 64, height: 64)
                                CachedImage(urlString: s.stickerCatalog?.imageUrl) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(Color.sand).font(.system(size: 24))
                                }
                                .frame(width: 64, height: 64)
                                .clipShape(Circle())
                            }
                            Text(s.stickerCatalog?.name ?? "Sticker")
                                .font(BT.caption1)
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                        }
                        .frame(width: 72)
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }
        }
    }

    /// Los lugares que recomienda. Tocar uno abre su ficha en el mapa, igual que
    /// desde el perfil propio.
    private var sharesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("LUGARES QUE RECOMIENDA", count: vm.shares.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 3) {
                    ForEach(vm.shares, id: \.id) { place in
                        NavigationLink(value: place) {
                            NearbyPlaceCard(place: place, subtitleOverride: place.photoLabel) {}
                                .allowsHitTesting(false)
                        }
                        .buttonStyle(.plain)
                        .onAppear { vm.shareAppeared(place) }
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }
        }
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("TRIPS", count: vm.journeys.count)
            let columns = [GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3)]
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(vm.journeys, id: \.id) { journey in
                    TripGridCell(journey: journey)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .onTapGesture { Haptic.light(); selectedStory = journey }
                        // Sin contextMenu de eliminar: no son sus publicaciones.
                        .onAppear { vm.tripAppeared(journey) }
                }
            }
            .padding(.horizontal, Spacing.edge)

            if vm.tripsHasMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
            }
        }
    }

    /// `icon` opcional: el vacío de "todavía no ha compartido nada" va sin él.
    /// Unos destellos encima de esa frase la convertían en un cartel, cuando es
    /// solo una constatación — la persona acaba de empezar. El fallo de carga sí
    /// lo lleva, porque ahí el icono dice qué salió mal.
    private func emptyState(_ text: String, icon: String? = nil) -> some View {
        VStack(spacing: Spacing.sm) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.inkMuted)
            }
            Text(text)
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
    }

    private static let memberSinceFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "MMMM yyyy"
        return f
    }()
    private static func memberSince(_ date: Date) -> String {
        memberSinceFormatter.string(from: date).capitalized
    }
}
