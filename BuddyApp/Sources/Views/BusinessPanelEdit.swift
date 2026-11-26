import SwiftUI
import PhotosUI

// El dueño abre su lugar desde Mi negocio > Ubicaciones y ve el MISMO mapa y el
// MISMO panel que el visitante, con lo editable a mano (Keyla, 21 Nov 2026):
// "Añadir foto" en Fotos, la descripción en Información y "Añadir producto" en
// Productos. Nada de pantallas nuevas: el panel lee este contexto del entorno.

struct BusinessEditContext: Equatable {
    let businessId: String
    let locationId: String
    let spotId: String
}

private struct BusinessEditKey: EnvironmentKey {
    static let defaultValue: BusinessEditContext? = nil
}

extension EnvironmentValues {
    var businessEdit: BusinessEditContext? {
        get { self[BusinessEditKey.self] }
        set { self[BusinessEditKey.self] = newValue }
    }
}

/// Ruta desde Ubicaciones: abre el lugar como en Inicio, en modo edición.
struct BusinessPlaceRoute: Hashable {
    let businessId: String
    let locationId: String
    let spotId: String
    let destinationId: String?
    let name: String
    let lat: Double
    let lng: Double
    var noPlace: Bool = false
}

/// El lugar del dueño como lo abre Inicio, en modo edición. Si el destino aún no
/// llegó (se tocó la tarjeta muy rápido), lo busca antes de abrir el mapa: sin
/// destino el mapa no trae su panel.
struct BusinessPlaceScreen: View {
    let route: BusinessPlaceRoute
    @State private var destinationId: String?
    @State private var resolved = false

    var body: some View {
        if route.noPlace {
            // Sin local: el mismo panel sin mapa, en modo edición.
            NoPlacePanelScreen(spotId: route.spotId, name: route.name, lat: route.lat, lng: route.lng)
                .environment(\.businessEdit, BusinessEditContext(businessId: route.businessId,
                                                                 locationId: route.locationId, spotId: route.spotId))
        } else {
            mapScreen
        }
    }

    private var mapScreen: some View {
        Group {
            if resolved {
                PlaceGuideMapSheet(destinationId: destinationId, focusPlaceId: route.spotId,
                                   name: route.name, lat: route.lat, lng: route.lng)
                    .environment(\.businessEdit, BusinessEditContext(businessId: route.businessId,
                                                                     locationId: route.locationId, spotId: route.spotId))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard !resolved else { return }
            destinationId = route.destinationId
            if destinationId == nil,
               let found = try? await APIClient.shared.searchCuratedSpots(query: route.name) {
                destinationId = found.first { $0.id.lowercased() == route.spotId.lowercased() }?.destinationId
                dlog("🏪 [BusinessPlace] buscar destino \(route.spotId.prefix(8)) → \(found.map { "\($0.id.prefix(8)):\($0.destinationId ?? "nil")" }) → \(destinationId ?? "nil")")
            }
            resolved = true
        }
    }
}

/// Negocio sin local físico (Keyla, 22 Nov 2026): el MISMO panel del lugar, ya
/// abierto a pantalla completa, sin mapa detrás. Botón verde "Pedir por chat".
/// Volver: el chevron redondo o deslizar a la derecha. En Mi negocio, el mismo
/// panel en modo edición (lo da el entorno businessEdit).
struct NoPlacePanelScreen: View {
    let spotId: String
    let name: String
    var category: String? = nil
    var cover: String? = nil
    var lat: Double = 0
    var lng: Double = 0
    @Environment(\.dismiss) private var dismiss

    private var place: Place {
        var p = APIPlaceGuideSpot(id: spotId, name: name, lat: lat, lng: lng, coverUrl: cover).asPlace
        p.categoryName = category
        return p
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleBackButton { dismiss() }
                Spacer()
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, 8)
            PlaceGuideDetailSheet(
                place: place, destinationId: nil, buddyPresenceText: nil,
                isFavorite: false, onToggleFavorite: {},
                onNavigate: {}, onClose: { dismiss() },
                expanded: true,
                actionTitle: "Pedir por chat", actionIcon: "bubble.left.and.text.bubble.right",
                actionOpensChat: true,
                showsClose: false
            )
            Spacer(minLength: 0)
        }
        .background(Color.surface.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        // Deslizar a la derecha vuelve, como el panel del mapa (regla 28).
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { v in
                    let w = v.translation.width, h = v.translation.height
                    if w > 90, w > abs(h) * 2 { Haptic.light(); dismiss() }
                }
        )
    }
}

/// La tarjeta punteada de "Añadir foto" del panel del lugar, para cualquier "añadir".
struct DashedAddTile: View {
    let title: String
    var loading = false
    var side: CGFloat = 115
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.surface)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            if loading {
                ProgressView().tint(Color.inkMuted)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 20, weight: .light)).foregroundStyle(Color.brand)
                    Text(title).font(.system(size: 11)).foregroundStyle(Color.inkMuted)
                }
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
    }
}

/// Fotos del dueño por lugar, compartidas entre la tarjeta "Añadir foto", la fila
/// y la portada en Mi negocio. Viven en el servidor: el feed las usa de portada
/// con prioridad (Keyla, 22 Nov 2026).
/// Inicio guarda su lista de lugares; tras un cambio del dueño (foto, portada,
/// cobertura) se vuelve a pedir para que la portada nueva se vea al volver.
@MainActor
func refreshInicioAfterOwnerChange(_ reason: String) {
    let loc = LocationService.current?.userLocation
    Task {
        await SpotsStore.shared.refresh(lat: loc?.coordinate.latitude, lng: loc?.coordinate.longitude,
                                        reason: reason)
    }
}

@MainActor
final class OwnerPhotoStore: ObservableObject {
    static let shared = OwnerPhotoStore()
    @Published private(set) var bySpot: [String: [OwnerPhoto]] = [:]
    @Published var uploading: Set<String> = []
    @Published var errorText: String?

    func photos(_ spotId: String) -> [OwnerPhoto] { bySpot[spotId] ?? [] }
    func cover(_ spotId: String) -> String? { photos(spotId).first?.url }

    func load(_ spotId: String) async {
        guard let list = try? await APIClient.shared.fetchOwnerPhotos(spotId: spotId) else { return }
        // Una lectura que salió antes de terminar una subida llega vacía: no borra la foto recién subida
        // (Keyla, 26 Nov 2026: la tarjeta de una ubicación nueva quedaba gris).
        if list.isEmpty, !(bySpot[spotId] ?? []).isEmpty { return }
        bySpot[spotId] = list
    }

    func add(_ ctx: BusinessEditContext, images: [Data]) async {
        uploading.insert(ctx.spotId)
        defer { uploading.remove(ctx.spotId) }
        errorText = nil
        for data in images {
            do {
                let p = try await APIClient.shared.uploadOwnerPhoto(spotId: ctx.spotId, farmId: ctx.businessId, imageData: data)
                bySpot[ctx.spotId, default: []].append(p)
                refreshInicioAfterOwnerChange("foto del dueño")
            } catch {
                errorText = "No pudimos subir una foto. Intenta de nuevo."
                dlog("🏪 [OwnerPhotos] subir falló: \(error)")
            }
        }
        Haptic.success()
    }

    func makeCover(_ ctx: BusinessEditContext, _ photo: OwnerPhoto) async {
        do {
            try await APIClient.shared.setOwnerCover(spotId: ctx.spotId, farmId: ctx.businessId, photoId: photo.id)
            var list = photos(ctx.spotId).filter { $0.id != photo.id }
            list.insert(photo, at: 0)
            bySpot[ctx.spotId] = list
            refreshInicioAfterOwnerChange("portada del dueño")
            Haptic.success()
        } catch { errorText = "No pudimos cambiar la portada." }
    }

    func remove(_ ctx: BusinessEditContext, _ photo: OwnerPhoto) async {
        do {
            try await APIClient.shared.deleteOwnerPhoto(spotId: ctx.spotId, farmId: ctx.businessId, photoId: photo.id)
            bySpot[ctx.spotId] = photos(ctx.spotId).filter { $0.id != photo.id }
            refreshInicioAfterOwnerChange("foto del dueño quitada")
        } catch { errorText = "No pudimos quitar la foto." }
    }
}

/// "Añadir foto" del dueño: la misma tarjeta punteada, abre el selector de fotos
/// y sube cada foto al lugar (JPEG de hasta 1600 px, igual que Mi negocio).
struct BusinessAddPhotoTile: View {
    let ctx: BusinessEditContext
    @ObservedObject private var store = OwnerPhotoStore.shared
    @State private var showCapture = false
    private let maxPhotos = 10

    var body: some View {
        let count = store.photos(ctx.spotId).count
        // Cámara al instante, con la galería en la misma pantalla (Keyla, 26 Nov 2026).
        Button { showCapture = true } label: {
            DashedAddTile(title: "Añadir foto", loading: store.uploading.contains(ctx.spotId))
        }
        .buttonStyle(.plain)
        .disabled(store.uploading.contains(ctx.spotId) || count >= maxPhotos)
        .photoCapture(isPresented: $showCapture, maxCount: max(1, maxPhotos - count)) { datas in
            Task { await store.add(ctx, images: datas) }
        }
        .task { await store.load(ctx.spotId) }
    }
}

/// Las fotos del dueño en esta fila, del mismo tamaño que las demás. Mantener
/// presionada una: "Usar como portada" o "Quitar foto".
struct BusinessLocalPhotos: View {
    let ctx: BusinessEditContext
    var side: CGFloat = 115
    /// Alto de la foto; nil = cuadrada (Keyla, 23 Nov 2026: fotos más altas en el panel).
    var height: CGFloat? = nil
    /// Tocar una foto abre el visor de siempre (el mismo de las demás fotos).
    var onOpen: (String) -> Void = { _ in }
    var zoom: Namespace.ID? = nil
    @ObservedObject private var store = OwnerPhotoStore.shared
    @State private var pendingRemoval: OwnerPhoto?

    var body: some View {
        ForEach(Array(store.photos(ctx.spotId).enumerated()), id: \.element.id) { i, photo in
            CachedImage(urlString: photo.url) { img in img.resizable().scaledToFill() }
                .frame(width: side, height: height ?? side)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .modifier(OptionalZoomSource(id: photo.url, namespace: zoom))
                .contentShape(Rectangle())
                .onTapGesture { onOpen(photo.url) }
                .contextMenu {
                    if i != 0 {
                        Button { Task { await store.makeCover(ctx, photo) } } label: { Label("Usar como portada", systemImage: "star") }
                    }
                    Button(role: .destructive) { pendingRemoval = photo } label: { Label("Quitar foto", systemImage: "trash") }
                }
        }
        .confirmationDialog("¿Quitar esta foto?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Quitar foto", role: .destructive) {
                if let p = pendingRemoval { Task { await store.remove(ctx, p) } }
                pendingRemoval = nil
            }
        } message: { Text("Los visitantes ya no la verán.") }
    }
}

/// Lo mismo para el visitante: las fotos del dueño primero en la fila, sin menú.
struct OwnerPhotosRow: View {
    let spotId: String
    var side: CGFloat = 115
    /// Alto de la foto; nil = cuadrada (Keyla, 23 Nov 2026: fotos más altas en el panel).
    var height: CGFloat? = nil
    var onOpen: (String) -> Void = { _ in }
    var zoom: Namespace.ID? = nil
    @ObservedObject private var store = OwnerPhotoStore.shared

    var body: some View {
        ForEach(store.photos(spotId)) { photo in
            CachedImage(urlString: photo.url) { img in img.resizable().scaledToFill() }
                .frame(width: side, height: height ?? side)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .modifier(OptionalZoomSource(id: photo.url, namespace: zoom))
                .contentShape(Rectangle())
                .onTapGesture { onOpen(photo.url) }
                .accessibilityAddTraits(.isButton)
        }
        .task { await store.load(spotId) }
    }
}

/// La descripción del negocio, editable en la pestaña Información. Mismo cuadro
/// de texto que "Información general" en Mi negocio.
struct BusinessPanelAbout: View {
    let ctx: BusinessEditContext
    @ObservedObject private var store = AccountStore.shared
    @State private var text = ""
    @FocusState private var focused: Bool
    private let maxAbout = 300

    private var saved: String { store.businesses.first { $0.id == ctx.businessId }?.about ?? "" }
    private var changed: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Cuenta qué ofreces, qué te hace especial y qué puede vivir el visitante.")
                        .font(BT.callout).foregroundStyle(Color.inkMuted)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(BT.callout).foregroundStyle(Color.ink)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .frame(minHeight: 110)
                    .onChange(of: text) { _, t in if t.count > maxAbout { text = String(t.prefix(maxAbout)) } }
            }
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Text("\(text.count) de \(maxAbout)").font(BT.caption1).foregroundStyle(Color.inkMuted)
                Spacer()
                if changed {
                    Button {
                        guard var b = store.businesses.first(where: { $0.id == ctx.businessId }) else { return }
                        b.about = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.update(b)
                        focused = false
                        Haptic.success()
                    } label: {
                        Text("Guardar").font(BT.footnoteBold).foregroundStyle(Color.inkInverse)
                            .padding(.horizontal, 18).frame(height: 36).background(Color.brand, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .onAppear { text = saved }
    }
}

// MARK: - Cobertura de entrega (Keyla, 22 Nov 2026)
// Destinos (distritos) donde el negocio entrega. El visitante ve una fila
// "Cobertura" en Información; el dueño la edita ahí mismo, con la búsqueda de
// destinos que ya usa la app.

@MainActor
final class CoverageStore: ObservableObject {
    static let shared = CoverageStore()
    @Published private(set) var bySpot: [String: [CoverageDestination]] = [:]

    func list(_ spotId: String) -> [CoverageDestination] { bySpot[spotId] ?? [] }

    func load(_ spotId: String) async {
        if let l = try? await APIClient.shared.fetchCoverage(spotId: spotId) { bySpot[spotId] = l }
    }

    func save(_ ctx: BusinessEditContext, _ list: [CoverageDestination]) async -> Bool {
        do {
            bySpot[ctx.spotId] = try await APIClient.shared.setCoverage(spotId: ctx.spotId, farmId: ctx.businessId,
                                                                        destinationIds: list.map(\.id))
            refreshInicioAfterOwnerChange("cobertura")
            Haptic.success()
            return true
        } catch { return false }
    }
}

/// Fila de Información: "Cobertura · Entrega a domicilio en Breña, San Isidro".
/// Sin cobertura no se muestra nada.
struct CoverageRow: View {
    let spotId: String
    @ObservedObject private var store = CoverageStore.shared

    var body: some View {
        let names = store.list(spotId).compactMap(\.name)
        Group {
            if !names.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cobertura").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    Text("Entrega a domicilio en " + names.joined(separator: ", "))
                        .font(BT.footnote).foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await store.load(spotId) }
    }
}

/// Elegir destinos: chips con "x" y el buscador de destinos de la app. Lo usan
/// "Cobertura" (en Información) y "No tengo local físico" (Agregar ubicación).
struct DestinationChipsPicker: View {
    @Binding var selection: [CoverageDestination]
    var placeholder = "Agrega un lugar, ej. Breña"
    /// Sobre el fondo de la pantalla va en blanco; dentro del panel, en el tono del fondo.
    var fieldColor: Color = .canvas
    @State private var query = ""
    @State private var results: [APIDestination] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !selection.isEmpty {
                FlowChips(items: selection) { d in selection.removeAll { $0.id == d.id } }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.inkMuted)
                TextField(placeholder, text: $query)
                    .font(BT.callout)
                    .autocorrectionDisabled()
                    .onChange(of: query) { _, q in search(q) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(fieldColor, in: Capsule())
            ForEach(results.filter { r in !selection.contains { $0.id == r.id } }.prefix(5)) { d in
                Button {
                    query = ""; results = []
                    selection.append(CoverageDestination(id: d.id, name: d.name))
                } label: {
                    HStack {
                        LocationPin(size: 13)
                        Text(d.name).font(BT.footnoteBold).foregroundStyle(Color.ink)
                        Spacer()
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.brand)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func search(_ q: String) {
        searchTask?.cancel()
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { results = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let r = (try? await APIClient.shared.searchDestinations(query: t, limit: 8))?.items ?? []
            // Sin repetir: la búsqueda puede traer el mismo destino dos veces.
            var seen = Set<String>()
            if !Task.isCancelled { results = r.filter { $0.source != "place" && seen.insert($0.id).inserted } }
        }
    }
}

/// "Cobertura" en Información: el mismo selector, y cada cambio se guarda.
struct CoverageEditor: View {
    let ctx: BusinessEditContext
    @ObservedObject private var store = CoverageStore.shared
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cobertura").font(BT.footnoteBold).foregroundStyle(Color.ink)
            DestinationChipsPicker(selection: Binding(
                get: { store.list(ctx.spotId) },
                set: { new in
                    Task {
                        let ok = await store.save(ctx, new)
                        errorText = ok ? nil : "No pudimos guardar. Intenta de nuevo."
                    }
                }))
            if let errorText { Text(errorText).font(BT.caption1).foregroundStyle(Color.errorRed) }
        }
        .task { await store.load(ctx.spotId) }
    }
}

/// Chips de destinos con una "x" para quitar, en filas que se acomodan solas.
private struct FlowChips: View {
    let items: [CoverageDestination]
    let onRemove: (CoverageDestination) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { d in
                    HStack(spacing: 6) {
                        Text(d.name ?? "").font(BT.footnote).foregroundStyle(Color.brand)
                        Button { onRemove(d) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.brand)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Quitar \(d.name ?? "")")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.sageTint, in: Capsule())
                }
            }
        }
    }
}

// MARK: - Nuevo producto en pasos

/// Nuevo producto en 3 pasos (Keyla, 23 Nov 2026): 1 Foto, 2 Nombre,
/// 3 Presentación. Mismo estilo que "Agrega tu negocio": una pregunta por
/// pantalla, contador arriba, botón grande abajo. Al crear: producto en la
/// tienda, su presentación y la foto en esa presentación.
struct NewProductFlow: View {
    let farmId: String

    enum Step: Int { case photo = 1, name, presentation }
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .photo
    @State private var showCapture = false
    @State private var photo: UIImage?
    @State private var name = ""
    @State private var desc = ""
    @State private var size = "250"
    @State private var unit = "g"
    @State private var price = ""
    @State private var busy = false
    @State private var errorText: String?
    // Llaves fijas: reintentar "Crear" no duplica nada.
    @State private var productKey = UUID().uuidString
    @State private var presKey = UUID().uuidString
    @State private var photoKey = UUID().uuidString
    @State private var createdProductId: String?
    @State private var createdPresId: String?
    @FocusState private var focus: Field?
    enum Field { case name, size, price }
    private let units = ["g", "kg", "ml", "L", "unidad"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    switch step {
                    case .photo: photoStep
                    case .name: nameStep
                    case .presentation: presentationStep
                    }
                    if let errorText { Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed) }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            // Regla 30: volver y seguir, abajo, donde está el pulgar (sobre la barra de pestañas).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    // En el paso 1 el mismo botón cierra el flujo sin guardar (Keyla, 23 Nov 2026).
                    CircleBackButton { goBack() }
                    footer
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, 8)
                .padding(.bottom, 96)
                .background(Color.canvas)
            }
        }
        .background(Color.canvas)
        .navigationTitle("Nuevo producto")
        .navigationBarTitleDisplayMode(.inline)
        // Un solo botón de volver (abajo, junto al principal) y el deslizar a la derecha.
        .navigationBarBackButtonHidden(true)
        .animation(.easeInOut(duration: 0.2), value: step)
        .photoCapture(isPresented: $showCapture) { datas in
            if let d = datas.first, let img = UIImage(data: d) { photo = img }
        }
    }

    // MARK: Encabezado (igual que Agrega tu negocio)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(1...3, id: \.self) { i in
                    Capsule().fill(i <= step.rawValue ? Color.brand : Color.hairline).frame(height: 4)
                }
            }
            .accessibilityHidden(true)
            Text("Paso \(step.rawValue) de 3").font(BT.caption1).foregroundStyle(Color.inkMuted)
            Text(title).font(.system(.title2).weight(.bold)).foregroundStyle(Color.brand)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, Spacing.edge)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch step {
        case .photo: return "Foto del producto"
        case .name: return "¿Cómo se llama?"
        case .presentation: return "Tamaño y precio"
        }
    }

    // MARK: Paso 1: la foto (la misma tarjeta del producto, apagada con un "+")

    private var photoStep: some View {
        Button { showCapture = true } label: {
            ZStack {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFill()
                } else {
                    Color.paleSage
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.white)
                        .frame(width: 52, height: 52).background(Color.brand, in: Circle())
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo == nil ? "Elegir foto" : "Cambiar foto")
    }

    // MARK: Paso 2: nombre (y descripción opcional)

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TextField("Ej. Café tostado", text: $name)
                .focused($focus, equals: .name)
                .font(BT.callout)
                .padding(.horizontal, 16).frame(height: 50)
                .background(Color.surface, in: Capsule())
                .cardShadow()
            TextField("Descripción (opcional)", text: $desc, axis: .vertical)
                .lineLimit(2...4)
                .font(BT.callout)
                .padding(14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                .cardShadow()
        }
        .onAppear { focus = .name }
    }

    // MARK: Paso 3: la presentación (tamaño, unidad, precio)

    @ViewBuilder
    private var presentationStep: some View {
        HStack(spacing: 8) {
            TextField("Tamaño", text: $size).keyboardType(.decimalPad)
                .focused($focus, equals: .size)
                .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                .background(Color.surface, in: Capsule())
            Menu {
                ForEach(units, id: \.self) { u in Button(u) { unit = u } }
            } label: {
                HStack(spacing: 4) {
                    Text(unit).foregroundStyle(Color.ink)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.brand)
                }
                .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                .background(Color.surface, in: Capsule())
            }
            TextField("S/ precio", text: $price).keyboardType(.decimalPad)
                .focused($focus, equals: .price)
                .font(BT.callout).padding(.horizontal, 12).frame(height: 44)
                .background(Color.surface, in: Capsule())
        }
        .onAppear { focus = .price }
        previewCard
    }

    // Regla 31: antes de crear se ve como lo verá el visitante; tocar una parte vuelve a su paso.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ASÍ LO VERÁN")
                .font(BT.eyebrow).tracking(2).foregroundStyle(Color.inkMuted)
                .padding(.top, Spacing.lg)
            HStack(alignment: .top, spacing: 12) {
                Button { focus = nil; step = .photo } label: {
                    Group {
                        if let photo { Image(uiImage: photo).resizable().scaledToFill() } else { Color.paleSage }
                    }
                    .frame(width: 115, height: 115)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cambiar foto")
                VStack(alignment: .leading, spacing: 6) {
                    Button { focus = nil; step = .name } label: {
                        HStack(spacing: 6) {
                            Text(name.trimmingCharacters(in: .whitespaces)).font(BT.headline).foregroundStyle(Color.ink)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.brand)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cambiar nombre")
                    if let p = number(price) {
                        Text(String(format: "S/ %.2f", p)).font(BT.footnoteBold).foregroundStyle(Color.brand)
                    }
                    Text("\(size) \(unit)").font(BT.footnote).foregroundStyle(Color.inkMuted)
                }
            }
        }
    }

    // MARK: Botón de abajo

    private var canGoOn: Bool {
        switch step {
        case .photo: return photo != nil
        case .name: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .presentation: return number(size).map { $0 > 0 } == true && number(price).map { $0 >= 0 } == true
        }
    }

    private var footer: some View {
        Button {
            focus = nil
            switch step {
            case .photo: step = .name
            case .name: step = .presentation
            case .presentation: Task { await create() }
            }
        } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(Color.inkInverse) }
                Text(step == .presentation ? "Crear producto" : "Siguiente").font(BT.footnoteBold)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(canGoOn ? Color.brand : Color.inkMuted.opacity(0.2), in: Capsule())
            .foregroundStyle(canGoOn ? Color.inkInverse : Color.inkMuted)
        }
        .buttonStyle(.plain)
        .disabled(!canGoOn || busy)
    }

    private func goBack() {
        focus = nil
        switch step {
        case .photo: dismiss()
        case .name: step = .photo
        case .presentation: step = .name
        }
    }

    private func number(_ t: String) -> Double? {
        Double(t.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    // MARK: Crear: producto en la tienda, presentación y foto

    private func create() async {
        guard let s = number(size), let p = number(price), let img = photo else { return }
        errorText = nil
        busy = true
        defer { busy = false }
        do {
            let productId: String
            if let id = createdProductId { productId = id } else {
                productId = try await FincasAuth.createProduct(farmId: farmId, name: name.trimmingCharacters(in: .whitespaces),
                                                               description: desc, key: productKey)
                createdProductId = productId
                try await FincasAuth.updateProduct(farmId: farmId, productId: productId, fields: ["status": "active"])
            }
            let presId: String
            if let id = createdPresId { presId = id } else {
                guard let id = try await FincasAuth.createPresentation(
                    farmId: farmId, productId: productId,
                    fields: ["packSize": s, "unit": unit, "price": (p * 100).rounded() / 100, "visible": true],
                    key: presKey) else {
                    errorText = "No recibimos la presentación. Revisa tu lista de productos."
                    return
                }
                presId = id
                createdPresId = id
            }
            guard let jpg = img.limitedToMaxDimension(1600).jpegData(compressionQuality: 0.8) else { return }
            _ = try await FincasAuth.uploadPresentationPhoto(farmId: farmId, productId: productId, presentationId: presId,
                                                              jpeg: jpg, key: photoKey)
            Haptic.success()
            NotificationCenter.default.post(name: .fincasProductsChanged, object: farmId)
            refreshInicioAfterOwnerChange("producto nuevo")
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
