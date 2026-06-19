import SwiftUI
import PhotosUI

// MARK: – YO (PROFILE)

struct YoView: View {
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var routeStore: RouteStore
    @State private var user: APIUser? = nil
    @State private var stickers: [APIUserSticker] = []
    @State private var journeys: [APIJourney] = []
    @State private var isLoading = true
    @State private var editingBio = false
    @State private var bioText = ""
    @State private var isSavingBio = false
    @State private var avatarItem: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ZStack {
                        Color.canvas.ignoresSafeArea()
                        ProgressView().tint(Color.inkMuted)
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Apertura editorial — misma firma que Trips y Conexiones
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("TU PERFIL")
                                        .font(BT.eyebrow).tracking(2)
                                        .foregroundStyle(Color.inkMuted)
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("Tu")
                                            .font(BT.title1).foregroundStyle(Color.ink)
                                        Text("historia.")
                                            .font(BT.displayLarge).foregroundStyle(Color.sand)
                                    }
                                }
                                Spacer()
                                Button {
                                    Haptic.light()
                                    showLogoutConfirm = true
                                } label: {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(Color.inkMuted)
                                        .frame(width: 36, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, Spacing.edge)
                            .padding(.top, Spacing.md)

                            profileHeader
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.lg)

                            bioSection
                                .padding(.horizontal, Spacing.edge)
                                .padding(.top, Spacing.md)

                            stickerSection
                                .padding(.top, Spacing.md)

                            tripsSection
                                .padding(.top, Spacing.xl)
                        }
                        .padding(.bottom, 100)
                    }
                    .refreshable { await loadProfile() }
                    .background(Color.canvas)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("¿Cerrar sesión?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) {
                    AuthService.shared.signOut()
                    authState.isLoggedIn = false
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Tendrás que volver a verificar tu número de teléfono.")
            }
            .task { await loadProfile() }
            .onReceive(NotificationCenter.default.publisher(for: .stickerUnlocked)) { _ in
                Task { await loadProfile() }
            }
            // El grid solo cambia cuando se publica un trip — no en cada visita
            .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
                Task { await loadProfile() }
            }
        }
    }

    // MARK: – Profile Header (avatar + stats)

    private var profileHeader: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            // Avatar — tapeable para cambiar foto
            PhotosPicker(selection: $avatarItem, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.sandLight)
                        .frame(width: 88, height: 88)
                    CachedImage(urlString: user?.avatarUrl) { img in
                        img.resizable().scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    } placeholder: {
                        Image(systemName: "person.fill")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Color.sand)
                    }
                    if isUploadingAvatar {
                        Circle().fill(.black.opacity(0.4)).frame(width: 88, height: 88)
                        ProgressView().tint(.white)
                    }
                    // Badge editar
                    ZStack {
                        Circle().fill(Color.ink).frame(width: 26, height: 26)
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.inkInverse)
                    }
                    .offset(x: 2, y: 2)
                }
            }
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await uploadAvatar(item: item) }
            }

            // Identidad — el nombre lidera, luego la narrativa
            VStack(alignment: .leading, spacing: 3) {
                Text(user?.fullName ?? "Tú")
                    .font(BT.title3)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(metaLine)
                    .font(BT.subhead)
                    .foregroundStyle(Color.inkMuted)
                if let since = user?.memberSince {
                    Text("Viajando desde \(memberSinceLabel(date: since))")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: String {
        let trips = journeys.count
        let tripsLabel = trips == 1 ? "1 trip" : "\(trips) trips"
        let stickersLabel = stickers.isEmpty ? nil
            : (stickers.count == 1 ? "1 sticker" : "\(stickers.count) stickers")
        return [tripsLabel, stickersLabel].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: – Bio

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingBio {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    TextField("Cuéntanos algo sobre ti…", text: $bioText, axis: .vertical)
                        .font(BT.callout)
                        .foregroundStyle(Color.ink)
                        .lineLimit(3...5)
                        .padding(Spacing.sm)
                        .background(Color.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.sand, lineWidth: 1.5))

                    HStack(spacing: Spacing.sm) {
                        Button("Cancelar") {
                            bioText = user?.bio ?? ""
                            editingBio = false
                        }
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)

                        Spacer()

                        Button {
                            saveBio()
                        } label: {
                            if isSavingBio {
                                ProgressView().scaleEffect(0.7).tint(.white)
                            } else {
                                Text("Guardar")
                                    .font(BT.footnoteBold)
                            }
                        }
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, 7)
                        .background(Color.ink)
                        .foregroundStyle(Color.inkInverse)
                        .clipShape(Capsule())
                        .disabled(isSavingBio)
                    }
                }
            } else {
                // Toda la fila es tappeable — target ≥ 44pt
                Button {
                    bioText = user?.bio ?? ""
                    editingBio = true
                } label: {
                    HStack(alignment: .center, spacing: Spacing.sm) {
                        if let bio = user?.bio, !bio.isEmpty {
                            Text(bio)
                                .font(BT.callout)
                                .foregroundStyle(Color.ink)
                                .multilineTextAlignment(.leading)
                        } else {
                            Text("Cuéntale al mundo quién eres…")
                                .font(BT.callout)
                                .foregroundStyle(Color.inkMuted.opacity(0.7))
                        }
                        Spacer()
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.inkMuted)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: – Sticker Section (colección con slots de progresión)

    private var stickerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("STICKERS", count: stickers.count)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(stickers, id: \.id) { s in
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Color.sandLight)
                                    .frame(width: 64, height: 64)
                                if let urlStr = s.stickerCatalog?.imageUrl, let url = URL(string: urlStr) {
                                    AsyncImage(url: url) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFill()
                                        } else {
                                            Image(systemName: "star.fill")
                                                .foregroundStyle(Color.sand)
                                                .font(.system(size: 24))
                                        }
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(Circle())
                                } else {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(Color.sand)
                                        .font(.system(size: 24))
                                }
                            }
                            Text(s.stickerCatalog?.name ?? "Sticker")
                                .font(BT.caption1)
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Text(shortDateFromDate(s.unlockedAt))
                                .font(BT.caption2)
                                .foregroundStyle(Color.inkMuted)
                        }
                        .frame(width: 72)
                    }

                    // Slots vacíos punteados — muestran que hay más por coleccionar
                    ForEach(0..<max(0, 3 - stickers.count), id: \.self) { _ in
                        Circle()
                            .strokeBorder(Color.inkMuted.opacity(0.25),
                                          style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                            .frame(width: 64, height: 64)
                            .overlay(
                                Image(systemName: "questionmark")
                                    .font(.system(size: 18, weight: .light))
                                    .foregroundStyle(Color.inkMuted.opacity(0.3))
                            )
                            .frame(width: 72, alignment: .top)
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }

            Text("Cada sticker guarda un lugar que te recibió.")
                .font(BT.caption1)
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, Spacing.edge)
        }
    }

    // MARK: – Section header (consistente entre secciones)

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(BT.eyebrow)
                .tracking(1.5)
                .foregroundStyle(Color.ink)
            if count > 0 {
                Text("· \(count)")
                    .font(BT.eyebrow)
                    .foregroundStyle(Color.inkMuted)
            }
        }
        .padding(.horizontal, Spacing.edge)
    }

    // MARK: – Trips grid

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader("TRIPS", count: journeys.count)

            if journeys.isEmpty {
                // Empty state — invita a la acción, no lamenta el vacío
                Button {
                    NotificationCenter.default.post(name: .switchToTab, object: nil,
                                                    userInfo: ["tab": AppTab.trips.rawValue])
                } label: {
                    VStack(spacing: Spacing.sm) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(Color.inkMuted)
                        Text("Tu primer trip te espera")
                            .font(BT.callout)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Spacing.edge)
            } else {
                let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(journeys, id: \.id) { journey in
                        TripGridCell(journey: journey)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    }
                    // Celdas fantasma — completan la fila e invitan al próximo trip
                    let remainder = journeys.count % 3
                    let ghosts = remainder == 0 ? 0 : 3 - remainder
                    ForEach(0..<ghosts, id: \.self) { _ in
                        Button {
                            NotificationCenter.default.post(name: .switchToTab, object: nil,
                                                            userInfo: ["tab": AppTab.trips.rawValue])
                        } label: {
                            Color.surface
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundStyle(Color.inkMuted.opacity(0.6))
                                )
                                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, Spacing.edge)
            }
        }
    }

    // MARK: – Helpers

    private func saveBio() {
        guard let userId = AuthService.shared.userId else { return }
        isSavingBio = true
        Task {
            do {
                try await APIClient.shared.updateUserBio(userId: userId, bio: bioText)
                await loadProfile()
                await MainActor.run {
                    editingBio = false
                    isSavingBio = false
                    Haptic.success()
                }
            } catch {
                await MainActor.run { isSavingBio = false }
            }
        }
    }

    private func uploadAvatar(item: PhotosPickerItem) async {
        guard let userId = AuthService.shared.userId else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        // Redimensionar a max 400px
        guard let uiImg = UIImage(data: data),
              let jpegData = uiImg.limitedToMaxDimension(400).jpegData(compressionQuality: 0.85) else { return }
        await MainActor.run { isUploadingAvatar = true }
        do {
            let url = try await APIClient.shared.uploadAvatar(userId: userId, imageData: jpegData)
            await MainActor.run {
                user = user.map { u in
                    var copy = u; copy.avatarUrl = url; return copy
                }
                isUploadingAvatar = false
                Haptic.success()
            }
        } catch {
            await MainActor.run { isUploadingAvatar = false }
        }
    }

    private func loadProfile() async {
        // Spinner solo en la primera carga — los refresh son silenciosos
        if user == nil { isLoading = true }
        guard let userId = AuthService.shared.userId else { isLoading = false; return }

        async let userTask     = try? APIClient.shared.fetchUser(id: userId)
        async let stickersTask = try? APIClient.shared.fetchUserStickers(userId: userId)
        async let journeysTask = try? APIClient.shared.fetchUserJourneys(userId: userId)

        let (u, s, j) = await (userTask, stickersTask, journeysTask)
        user     = u
        stickers = s ?? []
        journeys = (j ?? []).filter { $0.status == "completed" || $0.status == "published" }
        isLoading = false
        // Sync collected status onto map pins
        await routeStore.syncCollectedStickers(userStickers: stickers)
    }

    private func memberSinceLabel(date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_PE")
        df.dateFormat = "MMMM yyyy"
        return df.string(from: date)
    }

    private func shortDateFromDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_PE")
        df.dateFormat = "d MMM"
        return df.string(from: date)
    }
}

// MARK: – JOURNEY CARD (list style, kept for other views)

struct JourneyCard: View {
    let journey: APIJourney

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CachedImage(urlString: journey.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    gradientFallback
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let dest = journey.destination {
                        Text(dest.city)
                            .font(BT.displayMedium)
                            .foregroundStyle(.white)
                    }
                }
                .padding(Spacing.md)
            }
            .frame(height: 160)
            .clipped()

            HStack {
                Text(journey.title ?? "viaje sin título")
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "heart").font(.system(size: 11))
                    Text("\(journey.likesCount ?? 0)").font(BT.caption1)
                }
                .foregroundStyle(Color.inkMuted)
            }
            .padding(Spacing.md)
            .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .padding(.bottom, Spacing.md)
    }

    private var gradientFallback: some View {
        LinearGradient(colors: [Color.tealDeep, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: – STICKER CIRCLE (legacy)

struct StickerCircle: View {
    let symbol: String
    let unlocked: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(unlocked ? Color.sandLight : Color.canvas)
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(
                    unlocked ? Color.sand.opacity(0.35) : Color.inkMuted.opacity(0.12),
                    lineWidth: 1.5
                ))
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(unlocked ? Color.sand : Color.inkMuted.opacity(0.25))
        }
    }
}

// MARK: - Trip grid cell (first memoir thumbnail)

struct TripGridCell: View {
    let journey: APIJourney
    @State private var thumbUrl: String? = nil
    @State private var localThumb: UIImage? = nil

    var body: some View {
        // Celda cuadrada: Color.clear define el layout, la imagen solo rellena
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = localThumb {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                } else {
                    CachedImage(urlString: thumbUrl ?? journey.destination?.coverUrl) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        LinearGradient(colors: [Color.tealDeep, Color.teal],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }
        .clipped()
        .contentShape(Rectangle())
        .task {
            // 1. Intentar servidor primero
            do {
                let pages = try await APIClient.shared.fetchJourneyPages(journeyId: journey.id)
                if let first = pages.first {
                    thumbUrl = first.thumbnailUrl
                    return
                }
            } catch {
                // Cancelación de SwiftUI (vista redibujada): el .task se relanza solo
                if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            }
            // 2. Fallback: thumbnail local — disco + decodificación FUERA del main thread
            let jId = journey.id
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                let localPages = MemoirPersistence.shared.load(journeyId: jId)
                guard let filename = localPages.first?.thumbnailFileName else { return nil }
                return MemoirPersistence.shared.loadThumbnail(filename, journeyId: jId)
            }.value
            if let img { localThumb = img }
        }
    }
}
