import SwiftUI
import PhotosUI

// MARK: – Container (switches book ↔ editor)

struct TripBookContainerView: View {
    let journey: APIJourney
    @StateObject private var bookVM: TripBookViewModel
    @Environment(\.dismiss) private var dismiss

    init(journey: APIJourney) {
        self.journey = journey
        _bookVM = StateObject(wrappedValue: TripBookViewModel(journeyId: journey.id))
    }

    var body: some View {
        Group {
            if bookVM.isEditing {
                TripCanvasEditorView(vm: bookVM.editingVM, bookVM: bookVM)
                    .id(bookVM.currentPageIndex)
            } else {
                TripBookView(bookVM: bookVM, journey: journey, onDismiss: { dismiss() })
            }
        }
        .animation(.easeInOut(duration: 0.22), value: bookVM.isEditing)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: – Book view (swipe pages + strip)

struct TripBookView: View {
    @ObservedObject var bookVM: TripBookViewModel
    let journey: APIJourney
    let onDismiss: () -> Void

    @State private var showFinishConfirm = false
    @State private var isFinishing = false
    @State private var tripStatus: String

    init(bookVM: TripBookViewModel, journey: APIJourney, onDismiss: @escaping () -> Void) {
        self.bookVM = bookVM
        self.journey = journey
        self.onDismiss = onDismiss
        _tripStatus = State(initialValue: journey.status ?? "planning")
    }

    private var isActive: Bool { tripStatus == "active" }

    var body: some View {
        ZStack {
            Color(white: 0.93).ignoresSafeArea()

            // Swipeable pages
            TabView(selection: $bookVM.currentPageIndex) {
                ForEach(Array(bookVM.pages.enumerated()), id: \.element.id) { index, page in
                    TripPageDisplayView(page: page, journeyId: journey.id)
                        .tag(index)
                        .onTapGesture { bookVM.enterEdit(at: index) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Top bar
            VStack {
                HStack(alignment: .center) {
                    // Cerrar
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.45), in: Circle())
                    }

                    Spacer()

                    // Título
                    VStack(spacing: 2) {
                        Text(journey.title ?? journey.destination?.name ?? "trip")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("Portadas · \(bookVM.pages.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    Spacer()

                    // Acción derecha: publicar (activo) o lápiz (completado)
                    if isActive {
                        Button {
                            Haptic.medium()
                            showFinishConfirm = true
                        } label: {
                            if isFinishing {
                                ProgressView().tint(.white)
                                    .frame(width: 38, height: 38)
                            } else {
                                HStack(spacing: 5) {
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("Cerrar")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.ink, in: Capsule())
                            }
                        }
                        .disabled(isFinishing)
                    } else {
                        Button { bookVM.enterEdit(at: bookVM.currentPageIndex) } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(Color.teal.opacity(0.85), in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)
                Spacer()
            }

            // Bottom strip
            VStack {
                Spacer()
                bottomStrip
            }
        }
        .navigationBarHidden(true)
        .confirmationDialog("¿Cerrar y publicar trip?", isPresented: $showFinishConfirm, titleVisibility: .visible) {
            Button("Cerrar y publicar") { finishTrip() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Tu trip quedará completado y visible para la comunidad.")
        }
    }

    private func finishTrip() {
        isFinishing = true
        let currentPages = bookVM.pages
        let jId = journey.id
        Task {
            try? await APIClient.shared.publishJourney(journeyId: jId, pages: currentPages)
            await MainActor.run {
                tripStatus = "completed"
                isFinishing = false
                Haptic.success()
                onDismiss()
            }
        }
    }

    private var bottomStrip: some View {
        VStack(spacing: 0) {
            Text("\(bookVM.currentPageIndex + 1) / \(bookVM.pages.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(bookVM.pages.enumerated()), id: \.element.id) { index, page in
                        TripPageThumbnailCard(
                            page: page,
                            journeyId: journey.id,
                            isSelected: bookVM.currentPageIndex == index
                        ) {
                            withAnimation(.spring(response: 0.3)) { bookVM.currentPageIndex = index }
                        }
                        .contextMenu {
                            Button { bookVM.enterEdit(at: index) } label: {
                                Label("Editar portada", systemImage: "pencil")
                            }
                            if bookVM.pages.count > 1 {
                                Divider()
                                Button(role: .destructive) {
                                    bookVM.deletePage(at: index)
                                } label: {
                                    Label("Eliminar portada", systemImage: "trash")
                                }
                            }
                        }
                    }
                    // Add page
                    Button { bookVM.addPage() } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.secondary.opacity(0.4),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                .frame(width: 58, height: 86)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            Text("Nueva")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .background(.ultraThinMaterial)
    }
}

// MARK: – Full-page display (read-only)

struct TripPageDisplayView: View {
    let page: CollagePage
    let journeyId: String
    @State private var thumbnail: UIImage? = nil
    @State private var bgImage:   UIImage? = nil

    private let bottomStripHeight: CGFloat = 132

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let bg = bgImage {
                    Image(uiImage: bg).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped()
                    Color.white.opacity(0.55)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Color(red: page.backgroundRGBA[safe: 0] ?? 1,
                          green: page.backgroundRGBA[safe: 1] ?? 1,
                          blue:  page.backgroundRGBA[safe: 2] ?? 1)
                }

                if let thumb = thumbnail {
                    Image(uiImage: thumb).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height - bottomStripHeight)
                        .clipped().transition(.opacity)
                } else if page.itemSnapshots.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Toca para agregar fotos")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(height: geo.size.height - bottomStripHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height).clipped()
        }
        .ignoresSafeArea()
        .onAppear { loadThumbnail(); loadBgImage() }
        .onChange(of: page.editVersion) { _, _ in thumbnail = nil; loadThumbnail() }
        .onChange(of: page.backgroundImageFile) { _, _ in loadBgImage() }
    }

    private func loadThumbnail() {
        guard let filename = page.thumbnailFileName else { return }
        let jId = journeyId
        Task.detached(priority: .userInitiated) {
            let img = MemoirPersistence.shared.loadThumbnail(filename, journeyId: jId)
            await MainActor.run { thumbnail = img }
        }
    }

    private func loadBgImage() {
        guard let filename = page.backgroundImageFile else { bgImage = nil; return }
        let jId = journeyId
        Task.detached(priority: .userInitiated) {
            let img = MemoirPersistence.shared.loadBackground(filename, journeyId: jId)
            await MainActor.run { bgImage = img }
        }
    }
}

// MARK: – Thumbnail card

struct TripPageThumbnailCard: View {
    let page: CollagePage
    let journeyId: String
    let isSelected: Bool
    let onTap: () -> Void
    @State private var thumbnail: UIImage? = nil

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: page.backgroundRGBA[safe: 0] ?? 1,
                                    green: page.backgroundRGBA[safe: 1] ?? 1,
                                    blue:  page.backgroundRGBA[safe: 2] ?? 1))
                        .frame(width: 58, height: 86)
                    if let thumb = thumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                            .frame(width: 58, height: 86)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.teal, lineWidth: 2.5)
                            .frame(width: 58, height: 86)
                    }
                }
                .shadow(color: .black.opacity(isSelected ? 0.25 : 0.1),
                        radius: isSelected ? 6 : 3, y: 2)
            }
        }
        .buttonStyle(.plain)
        .onAppear { loadThumbnail() }
        .onChange(of: page.editVersion) { _, _ in thumbnail = nil; loadThumbnail() }
    }

    private func loadThumbnail() {
        guard let filename = page.thumbnailFileName else { return }
        let jId = journeyId
        Task.detached(priority: .userInitiated) {
            let img = MemoirPersistence.shared.loadThumbnail(filename, journeyId: jId)
            await MainActor.run { thumbnail = img }
        }
    }
}

// MARK: – Canvas editor (HomeView adapted)

private enum ActivePanel: Equatable { case none, edge, border, layout, crop }

struct TripCanvasEditorView: View {
    @ObservedObject var vm: CanvasViewModel
    @ObservedObject var bookVM: TripBookViewModel

    @State private var canvasSize: CGSize = .zero
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera      = false
    @State private var showFreeCrop    = false
    @State private var activePanel: ActivePanel = .none

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)

    // El lienzo mide EXACTAMENTE lo que mide la publicación en el feed —
    // lo que ves al editar es lo que se publica. Única fuente de verdad.
    private var pageSize: CGSize { CanvasViewModel.pageSize }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()

            CanvasView(vm: vm, canvasSize: $canvasSize)
                .frame(width: pageSize.width, height: pageSize.height)
                .clipped()
                .onTapGesture { vm.selectedItemId = nil; activePanel = .none }
                .overlay {
                    // Lienzo vacío: invitación directa, tap abre la galería
                    if vm.items.isEmpty && !vm.isProcessing {
                        Button { showPhotoPicker = true } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(Color.teal)
                                Text("Toca para agregar tus fotos")
                                    .font(BT.callout)
                                    .foregroundStyle(Color.inkMuted)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(width: pageSize.width, height: pageSize.height)
                    }
                }

            if vm.isProcessing { processingOverlay }
            if bookVM.isLoadingPage { pageLoadingOverlay }

            // Top bar
            VStack {
                HStack {
                    Button {
                        activePanel = .none
                        bookVM.exitEdit(canvasSize: canvasSize)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.55), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    }
                    Spacer()
                    Text("\(bookVM.currentPageIndex + 1) / \(bookVM.pages.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                .padding(.top, 56).padding(.horizontal, 16)
                Spacer()
            }

            // Right tool column
            HStack {
                Spacer()
                VStack {
                    Spacer()
                    if vm.selectedItemId != nil {
                        rightToolColumn
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal:   .move(edge: .trailing).combined(with: .opacity)
                            ))
                    }
                    Spacer()
                }
                .padding(.bottom, 110)
            }
            .padding(.trailing, 12)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: vm.selectedItemId)

            // Bottom pill + panel
            VStack(spacing: 10) {
                subPanel
                mainPill
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 36)
            .animation(.spring(response: 0.35, dampingFraction: 0.78), value: activePanel)
        }
        .ignoresSafeArea()
        .photosPicker(isPresented: $showPhotoPicker,
                      selection: $photoPickerItems,
                      maxSelectionCount: 10,
                      matching: .images)
        .onChange(of: photoPickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerView { image in vm.addPhoto(image, in: pageSize) }.ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showFreeCrop) {
            if let sel = vm.selectedItem, !sel.isSticker {
                FreeCropView(
                    image: sel.image,
                    original: sel.originalImage,
                    onCancel: { showFreeCrop = false },
                    onApply: { cropped in
                        vm.setCroppedImage(id: sel.id, image: cropped)
                        showFreeCrop = false
                    }
                )
            }
        }
        .onChange(of: vm.selectedItemId) { _, id in if id == nil { activePanel = .none } }
        .alert("Error", isPresented: .constant(vm.errorMessage != nil)) {
            Button("OK") { vm.errorMessage = nil }
        } message: { Text(vm.errorMessage ?? "") }
    }

    // MARK: Right tool column

    private var rightToolColumn: some View {
        VStack(spacing: 0) {
            if let selected = vm.selectedItem {
                if selected.isSticker {
                    IGToolBtn(icon: "photo.fill", label: "Revertir", tint: Color.teal) {
                        activePanel = .none
                        vm.revertToPhoto(id: selected.id)
                    }
                } else {
                    // Convierte la foto en sticker (recorta el sujeto automáticamente)
                    IGToolBtn(icon: "wand.and.stars", label: "Sticker") {
                        activePanel = .none
                        Task { await vm.makeSticker(id: selected.id) }
                    }
                }
                toolDivider
                IGToolBtn(icon: "square.dashed", label: "Marco", active: activePanel == .border) {
                    withAnimation { activePanel = activePanel == .border ? .none : .border }
                }
                IGToolBtn(icon: "rectangle.split.2x2", label: "Diseño", active: activePanel == .layout) {
                    withAnimation { activePanel = activePanel == .layout ? .none : .layout }
                }
                if !selected.isSticker {
                    IGToolBtn(icon: "scissors", label: "Recortar") {
                        activePanel = .none
                        showFreeCrop = true
                    }
                }
                if let id = vm.selectedItemId {
                    IGToolBtn(icon: "plus.square.on.square", label: "Copiar") { vm.duplicateItem(id: id) }
                    if !selected.isSticker {
                        IGToolBtn(icon: "crop", label: "Bordes", active: activePanel == .edge) {
                            withAnimation { activePanel = activePanel == .edge ? .none : .edge }
                        }
                    }
                    toolDivider
                    IGToolBtn(icon: "trash", label: "Borrar", tint: .red) {
                        vm.deleteItem(id: id); activePanel = .none
                    }
                }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        // Fondo más sólido y claro que el letterbox — la barra no se funde con el negro
        .background(Color(white: 0.16).opacity(0.96), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private var toolDivider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 28, height: 0.5).padding(.vertical, 4)
    }

    // MARK: Main pill

    private var mainPill: some View {
        HStack(spacing: 0) {
            Button { activePanel = .none; bookVM.navigateToPrevious() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(bookVM.currentPageIndex > 0 ? .white : .white.opacity(0.25))
                    .frame(width: 52, height: 60)
            }
            .buttonStyle(.plain).disabled(bookVM.currentPageIndex == 0)

            pillDivider

            Button { activePanel = .none; showCamera = true } label: {
                VStack(spacing: 4) {
                    Image(systemName: "camera.fill").font(.system(size: 20, weight: .semibold))
                    Text("Cámara").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white).frame(width: 68, height: 60)
            }.buttonStyle(.plain)

            pillDivider

            Button { activePanel = .none; showPhotoPicker = true } label: {
                VStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 20, weight: .semibold))
                    Text("Galería").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white).frame(width: 68, height: 60)
            }.buttonStyle(.plain)

            pillDivider

            Button { activePanel = .none; bookVM.exitEdit(canvasSize: canvasSize) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .semibold))
                    Text("Guardar").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.teal).frame(width: 68, height: 60)
            }.buttonStyle(.plain)

            pillDivider

            Button { activePanel = .none; bookVM.navigateToNext() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(bookVM.currentPageIndex < bookVM.pages.count - 1 ? .white : .white.opacity(0.25))
                    .frame(width: 52, height: 60)
            }
            .buttonStyle(.plain).disabled(bookVM.currentPageIndex >= bookVM.pages.count - 1)
        }
        .background(.black.opacity(0.72), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }

    private var pillDivider: some View {
        Rectangle().fill(.white.opacity(0.15)).frame(width: 0.5, height: 28)
    }

    // MARK: Sub panels

    @ViewBuilder
    private var subPanel: some View {
        switch activePanel {
        case .edge:   edgePanel.transition(.move(edge: .bottom).combined(with: .opacity))
        case .border: borderPanel.transition(.move(edge: .bottom).combined(with: .opacity))
        case .layout: layoutPanel.transition(.move(edge: .bottom).combined(with: .opacity))
        case .crop:   EmptyView()
        case .none:   EmptyView()
        }
    }

    // MARK: Layout panel — plantillas rápidas para acomodar las fotos

    private var layoutPanel: some View {
        HStack(spacing: 10) {
            layoutOption(.one,        label: "1 foto")
            layoutOption(.twoColumns, label: "2 vert.")
            layoutOption(.twoRows,    label: "2 horiz.")
            layoutOption(.grid4,      label: "4 fotos")
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func layoutOption(_ layout: CanvasViewModel.CanvasLayout, label: String) -> some View {
        Button {
            vm.applyLayout(layout, in: pageSize)
            lightHaptic.impactOccurred()
            withAnimation { activePanel = .none }
        } label: {
            VStack(spacing: 5) {
                LayoutPreview(layout: layout)
                    .frame(width: 34, height: 30)
                Text(label).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 60, height: 60)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var edgePanel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PhotoEdgeShape.allCases, id: \.self) { shape in
                    let isActive = vm.selectedItem?.edgeShape == shape
                    Button {
                        if let id = vm.selectedItemId { vm.setEdgeShape(shape, for: id); lightHaptic.impactOccurred() }
                    } label: {
                        VStack(spacing: 5) {
                            EdgeShapePreview(shape: shape).frame(width: 36, height: 28)
                            Text(shape.label).font(.system(size: 9, weight: .medium))
                                .foregroundStyle(isActive ? .black : .white.opacity(0.8))
                        }
                        .frame(width: 56, height: 56)
                        .background(isActive ? .white : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
        .frame(height: 72)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    private var borderPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([CGFloat(0), 7, 14, 25], id: \.self) { w in
                    let isActive = vm.selectedItem?.borderWidth == w
                    Button {
                        if let id = vm.selectedItemId {
                            let col = vm.selectedItem?.borderColor ?? .white
                            vm.setBorder(width: w, color: col == .clear ? .white : col, for: id)
                            lightHaptic.impactOccurred()
                        }
                    } label: {
                        Text(w == 0 ? "Off" : "\(Int(w))pt")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isActive ? .black : .white.opacity(0.8))
                            .frame(width: 52, height: 32)
                            .background(isActive ? .white : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16).padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(memoirBorderPalette, id: \.label) { entry in
                        let isActive = "\(vm.selectedItem?.borderColor ?? .clear)" == "\(entry.color)"
                                       && (vm.selectedItem?.borderWidth ?? 0) > 0
                        Button {
                            if let id = vm.selectedItemId {
                                let w = max(7, vm.selectedItem?.borderWidth ?? 7)
                                vm.setBorder(width: entry.color == .clear ? 0 : w, color: entry.color, for: id)
                                lightHaptic.impactOccurred()
                            }
                        } label: {
                            Circle()
                                .fill(entry.color == .clear ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(entry.color))
                                .frame(width: 32, height: 32)
                                .overlay(Circle().strokeBorder(isActive ? Color.yellow : .white.opacity(0.3),
                                                               lineWidth: isActive ? 2.5 : 1))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }.padding(.vertical, 10)
        }
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 12)
    }

    // MARK: Overlays

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).controlSize(.large)
                Text("Recortando sujeto…").foregroundStyle(.white).font(.system(size: 14, weight: .medium))
            }
            .padding(28).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var pageLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).controlSize(.large).scaleEffect(1.2)
                Text("Cargando portada…").foregroundStyle(.white).font(.system(size: 14, weight: .medium))
            }
            .padding(32).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }

    private func loadPhotos(_ pickerItems: [PhotosPickerItem]) async {
        // Decodificar Y reducir en background — el main thread solo inserta
        let images: [UIImage] = await withTaskGroup(of: UIImage?.self) { group in
            for item in pickerItems {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { return nil }
                    return img.limitedToMaxDimension(1200)
                }
            }
            var result: [UIImage] = []
            for await img in group { if let img { result.append(img) } }
            return result
        }
        // pageSize, no canvasSize: este último puede ser .zero tras cambiar de página
        for image in images { vm.addPhoto(image, in: pageSize) }
        photoPickerItems = []
    }
}

// MARK: – Shared helpers (scoped to avoid conflicts)

private struct IGToolBtn: View {
    let icon: String; let label: String
    var tint: Color = .white; var active: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    if active { Circle().fill(.white.opacity(0.18)).frame(width: 46, height: 46) }
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: active ? .bold : .medium))
                        .foregroundStyle(active ? Color.sand : tint)
                        .frame(width: 46, height: 46)
                }
                Text(label).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(active ? Color.sand : tint.opacity(0.85))
            }.padding(.horizontal, 4).padding(.vertical, 2)
        }.buttonStyle(.plain)
    }
}

private let memoirBorderPalette: [(label: String, color: Color)] = [
    ("Blanco", .white), ("Negro", .black),
    ("Crema",  Color(red: 0.98, green: 0.95, blue: 0.88)),
    ("Azul",   Color(red: 0.55, green: 0.80, blue: 1.0)),
    ("Rosa",   Color(red: 1.0,  green: 0.72, blue: 0.77)),
    ("Menta",  Color(red: 0.70, green: 0.95, blue: 0.80)),
    ("Arena",  Color(red: 0.93, green: 0.85, blue: 0.68)),
]

// MARK: – FREE CROP — el usuario elige exactamente de dónde a dónde recortar

struct FreeCropView: View {
    let image: UIImage
    let original: UIImage
    let onCancel: () -> Void
    let onApply: (UIImage) -> Void

    @State private var cropRect: CGRect = .zero
    @State private var dragStart: CGRect? = nil
    @State private var activeHandle: CropHandle? = nil

    private enum CropHandle { case tl, tr, bl, br, move }
    private let minSide: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancelar") { onCancel() }
                    .font(.system(size: 15)).foregroundStyle(.white)
                Spacer()
                Text("Recortar")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button("Aplicar") { apply() }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.sand)
            }
            .padding(.horizontal, 20)
            .padding(.top, 64)
            .padding(.bottom, 16)

            GeometryReader { geo in
                let imgSize = image.size
                let scale   = min(geo.size.width / max(imgSize.width, 1),
                                  geo.size.height / max(imgSize.height, 1))
                let fitted  = CGRect(
                    x: (geo.size.width  - imgSize.width  * scale) / 2,
                    y: (geo.size.height - imgSize.height * scale) / 2,
                    width:  imgSize.width  * scale,
                    height: imgSize.height * scale
                )

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                        .position(x: fitted.midX, y: fitted.midY)

                    // Velo oscuro fuera del área de recorte
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size))
                        p.addRect(cropRect)
                    }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    // Marco + tercios + esquinas
                    cropFrame
                }
                .contentShape(Rectangle())
                .gesture(cropGesture(fitted: fitted))
                .onAppear {
                    fittedRect = fitted
                    if cropRect == .zero { cropRect = fitted }
                }
            }

            // Restaurar original
            Button {
                onApply(original)
            } label: {
                Text("Restaurar original")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.vertical, 18)
        }
        .background(Color.black.ignoresSafeArea())
    }

    // Marco con líneas de tercios y agarres en las esquinas
    private var cropFrame: some View {
        ZStack {
            Rectangle()
                .strokeBorder(.white, lineWidth: 1.5)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)

            // Tercios
            ForEach(1..<3) { i in
                Rectangle().fill(.white.opacity(0.35))
                    .frame(width: 0.5, height: cropRect.height)
                    .position(x: cropRect.minX + cropRect.width * CGFloat(i) / 3, y: cropRect.midY)
                Rectangle().fill(.white.opacity(0.35))
                    .frame(width: cropRect.width, height: 0.5)
                    .position(x: cropRect.midX, y: cropRect.minY + cropRect.height * CGFloat(i) / 3)
            }

            // Agarres de esquina
            let corners = [CGPoint(x: cropRect.minX, y: cropRect.minY),
                           CGPoint(x: cropRect.maxX, y: cropRect.minY),
                           CGPoint(x: cropRect.minX, y: cropRect.maxY),
                           CGPoint(x: cropRect.maxX, y: cropRect.maxY)]
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .position(corners[i])
            }
        }
        .allowsHitTesting(false)
    }

    /// Clamp seguro: ordena los límites antes de aplicar — un rango invertido
    /// por error de coma flotante crasheaba con "lowerBound <= upperBound".
    private func clamp(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let lo = min(a, b), hi = max(a, b)
        return min(max(v, lo), hi)
    }

    private func cropGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeHandle == nil {
                    activeHandle = handle(at: value.startLocation)
                    dragStart = cropRect
                }
                guard let h = activeHandle, let start = dragStart else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                var r = start

                switch h {
                case .move:
                    r.origin.x = clamp(start.minX + dx, fitted.minX, fitted.maxX - start.width)
                    r.origin.y = clamp(start.minY + dy, fitted.minY, fitted.maxY - start.height)
                case .tl:
                    let nx = clamp(start.minX + dx, fitted.minX, start.maxX - minSide)
                    let ny = clamp(start.minY + dy, fitted.minY, start.maxY - minSide)
                    r = CGRect(x: nx, y: ny, width: start.maxX - nx, height: start.maxY - ny)
                case .tr:
                    let nx = clamp(start.maxX + dx, start.minX + minSide, fitted.maxX)
                    let ny = clamp(start.minY + dy, fitted.minY, start.maxY - minSide)
                    r = CGRect(x: start.minX, y: ny, width: nx - start.minX, height: start.maxY - ny)
                case .bl:
                    let nx = clamp(start.minX + dx, fitted.minX, start.maxX - minSide)
                    let ny = clamp(start.maxY + dy, start.minY + minSide, fitted.maxY)
                    r = CGRect(x: nx, y: start.minY, width: start.maxX - nx, height: ny - start.minY)
                case .br:
                    let nx = clamp(start.maxX + dx, start.minX + minSide, fitted.maxX)
                    let ny = clamp(start.maxY + dy, start.minY + minSide, fitted.maxY)
                    r = CGRect(x: start.minX, y: start.minY, width: nx - start.minX, height: ny - start.minY)
                }
                cropRect = r
            }
            .onEnded { _ in
                activeHandle = nil
                dragStart = nil
            }
    }

    /// Qué agarre tocó el usuario: esquinas con radio generoso de 36pt,
    /// el interior mueve el área completa.
    private func handle(at p: CGPoint) -> CropHandle? {
        let radius: CGFloat = 36
        func near(_ c: CGPoint) -> Bool { hypot(p.x - c.x, p.y - c.y) < radius }
        if near(CGPoint(x: cropRect.minX, y: cropRect.minY)) { return .tl }
        if near(CGPoint(x: cropRect.maxX, y: cropRect.minY)) { return .tr }
        if near(CGPoint(x: cropRect.minX, y: cropRect.maxY)) { return .bl }
        if near(CGPoint(x: cropRect.maxX, y: cropRect.maxY)) { return .br }
        if cropRect.contains(p) { return .move }
        return nil
    }

    /// Convierte el rect en pantalla a pixeles de la imagen y recorta.
    private func apply() {
        let img = image.normalized()
        // El rect fitted se recalcula igual que en body para mapear coordenadas
        // (no podemos leer GeometryReader aquí, así que derivamos del cropRect actual)
        guard cropRect.width > 0, cropRect.height > 0 else { onCancel(); return }

        // Reconstruir fitted: la imagen escalada que contiene al cropRect.
        // cropRect siempre está dentro de fitted, y fitted conserva el aspecto.
        // Guardamos fitted implícitamente: usamos la proporción contra la imagen.
        // Para un mapeo correcto recalculamos con el tamaño que tenía el contenedor:
        // el cropRect fue clampeado a fitted, así que basta el origen de fitted.
        // → Derivación robusta: tomamos fitted del estado del primer onAppear.
        guard let fitted = fittedRect else { onCancel(); return }

        let pxPerPt = (img.size.width * img.scale) / fitted.width
        let pixelRect = CGRect(
            x: (cropRect.minX - fitted.minX) * pxPerPt,
            y: (cropRect.minY - fitted.minY) * pxPerPt,
            width: cropRect.width * pxPerPt,
            height: cropRect.height * pxPerPt
        ).integral

        guard let cg = img.cgImage?.cropping(to: pixelRect) else { onCancel(); return }
        // standardizedFormat: sin él, el JPEG encoder rechaza el formato
        // de pixel heredado (HEIC/wide-color) al persistir
        onApply(UIImage(cgImage: cg, scale: img.scale, orientation: .up).standardizedFormat())
    }

    @State private var fittedRect: CGRect? = nil
}

// Mini diagrama de líneas para cada plantilla de layout
struct LayoutPreview: View {
    let layout: CanvasViewModel.CanvasLayout

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                switch layout {
                case .one:
                    EmptyView()
                case .twoColumns:
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: 1.5, height: h)
                case .twoRows:
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: w, height: 1.5)
                case .grid4:
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: 1.5, height: h)
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: w, height: 1.5)
                }
            }
        }
    }
}

struct EdgeShapePreview: View {
    let shape: PhotoEdgeShape
    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.gray.opacity(0.25).clipShape(previewShape())
                previewShape().stroke(.white.opacity(0.6), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    private func previewShape() -> AnyShape {
        switch shape {
        case .none:       AnyShape(Rectangle())
        case .tornBottom: AnyShape(TornBottomShape())
        case .tornTop:    AnyShape(TornTopShape())
        case .tornRight:  AnyShape(TornRightShape())
        case .tornLeft:   AnyShape(TornLeftShape())
        case .diagonalTR: AnyShape(DiagonalTRShape())
        case .diagonalBL: AnyShape(DiagonalBLShape())
        }
    }
}
