import SwiftUI
import MapKit

// MARK: – DESCUBRIR
// Full-screen Apple Maps with a calm bottom sheet.
// Pins are quiet by default; they respond on selection.

struct DescubrirView: View {
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var locationService: LocationService
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedPlace: Place? = nil
    @State private var sheetDetent: PresentationDetent = .fraction(0.35)
    @State private var showSheet = true

    var places: [Place] { routeStore.route.places }

    /// Los controles flotan justo encima del borde superior de la hoja —
    /// se reacomodan al cambiar de detent en vez de un offset fijo.
    private var controlBottomPadding: CGFloat {
        let screenH = UIScreen.main.bounds.height
        if sheetDetent == .medium { return screenH * 0.5 + Spacing.md }
        return screenH * 0.35 + Spacing.md
    }

    var body: some View {
        ZStack {
            Map(position: $camera) {
                ForEach(places) { place in
                    Annotation("", coordinate: place.coordinate) {
                        PlacePin(place: place, isSelected: selectedPlace?.id == place.id)
                            .frame(width: 44, height: 44)        // área tocable ≥44pt
                            .contentShape(Circle())
                            .onTapGesture {
                                Haptic.select()
                                withAnimation(.spring(response: 0.3)) {
                                    selectedPlace = selectedPlace?.id == place.id ? nil : place
                                }
                            }
                            .accessibilityLabel(place.name)
                            .accessibilityAddTraits(.isButton)
                    }
                }
                UserAnnotation()
            }
            .mapStyle(.standard(
                elevation: .flat,
                pointsOfInterest: .including([.cafe, .restaurant, .park]),
                showsTraffic: false
            ))
            .mapControls { EmptyView() }
            .ignoresSafeArea()
            .onTapGesture {
                guard selectedPlace != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) { selectedPlace = nil }
            }

            // Floating map controls — native material glass
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        MapControlButton(symbol: "location.fill") {
                            Haptic.light()
                            withAnimation { camera = .userLocation(fallback: .automatic) }
                        }
                        MapControlButton(symbol: "arrow.up.left.and.arrow.down.right") {
                            Haptic.light()
                            fitAll()
                        }
                    }
                    .padding(.trailing, Spacing.md)
                    .padding(.bottom, controlBottomPadding)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: sheetDetent)
                }
            }
        }
        .sheet(isPresented: $showSheet) {
            PlacesSheet(
                places: places,
                selectedPlace: $selectedPlace,
                onSelectPlace: { place in
                    Haptic.medium()
                    withAnimation(.spring(response: 0.4)) {
                        camera = .region(MKCoordinateRegion(
                            center: place.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
                        ))
                        selectedPlace = place
                    }
                }
            )
            .presentationDetents([.fraction(0.35), .medium, .large], selection: $sheetDetent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationCornerRadius(Radius.xl)
            .interactiveDismissDisabled()
        }
        .onAppear { fitAll() }
        .onChange(of: locationService.userLocation) { _, _ in fitAll() }
    }

    private func fitAll() {
        var coords = places.map(\.coordinate)
        if let u = locationService.userLocation?.coordinate { coords.append(u) }
        guard !coords.isEmpty else { return }
        let minLat = coords.map(\.latitude).min()!
        let maxLat = coords.map(\.latitude).max()!
        let minLon = coords.map(\.longitude).min()!
        let maxLon = coords.map(\.longitude).max()!
        let center = CLLocationCoordinate2D(
            latitude:  (minLat + maxLat) / 2 - (maxLat - minLat) * 0.15,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(maxLat - minLat, 0.006) * 2.6,
            longitudeDelta: max(maxLon - minLon, 0.006) * 2.6
        )
        withAnimation(.easeInOut(duration: 0.7)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}

// MARK: – PLACES BOTTOM SHEET

struct PlacesSheet: View {
    let places: [Place]
    @Binding var selectedPlace: Place?
    let onSelectPlace: (Place) -> Void
    var onAddFirstSpot: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let place = selectedPlace {
                    PlaceDetailSheet(place: place) {
                        withAnimation(.easeOut(duration: 0.2)) { selectedPlace = nil }
                    }
                    .transition(.opacity)
                } else {
                    PlaceListSheet(places: places, onSelect: onSelectPlace, onAddFirstSpot: onAddFirstSpot)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: selectedPlace?.id)
        }
    }
}

// MARK: – PLACE LIST SHEET

struct PlaceListSheet: View {
    let places: [Place]
    let onSelect: (Place) -> Void
    var onAddFirstSpot: (() -> Void)? = nil

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if places.isEmpty {
                    PlaceListEmptyState(onAddFirstSpot: onAddFirstSpot)
                        .padding(.top, Spacing.md)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recomendado por la comunidad")
                            .font(BT.displayMedium)
                            .foregroundStyle(Color.ink)
                        Text("\(places.count) sitio\(places.count == 1 ? "" : "s") recomendado\(places.count == 1 ? "" : "s") por viajeros y buddies")
                            .font(BT.footnote)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Spacing.md)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.sm) {
                            ForEach(Array(places.enumerated()), id: \.element.id) { i, place in
                                Button { onSelect(place) } label: {
                                    PlaceCard(place: place, index: i)
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                        .padding(.horizontal, Spacing.edge)
                        .padding(.bottom, Spacing.md)
                    }
                }
            }
        }
        .background(Color.canvas)
    }
}

private struct PlaceListEmptyState: View {
    var onAddFirstSpot: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Este lugar está\nsin explorar aún.")
                    .font(BT.displayMedium)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("La guía de cada lugar la construyen quienes lo conocen. Sé quien inicie la comunidad aquí y ayuda a los próximos viajeros a descubrirlo.")
                    .font(BT.footnote)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.edge)

            if let onAddFirstSpot {
                Button(action: onAddFirstSpot) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Agregar el primer sitio")
                            .font(BT.footnoteBold)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.brand)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                }
                .buttonStyle(.pressable)
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.lg)
            }
        }
    }
}

// MARK: – PLACE DETAIL SHEET

struct PlaceDetailSheet: View {
    let place: Place
    let onClose: () -> Void

    private var palette: [Color] {
        let all: [[Color]] = [
            [Color(hex: "4A2820"), Color(hex: "6E3B2D")],
            [Color(hex: "3D2B1A"), Color(hex: "6B4226")],
            [Color(hex: "4A3D35"), Color(hex: "7A6558")],
            [Color(hex: "5C3E1A"), Color(hex: "8B6428")],
        ]
        return all[abs(place.name.hashValue) % all.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(place.stickerEmoji).font(.system(size: 56))
            }
            .frame(height: 140)
            .clipped()

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(BT.title3)
                            .foregroundStyle(Color.ink)
                        Text(place.category.label)
                            .font(BT.caption1)
                            .foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.inkMuted)
                    }
                }

                Text(place.description)
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)

                Divider()

                HStack {
                    Label("a 5 min caminando", systemImage: "figure.walk")
                    Spacer()
                    Label("sticker disponible", systemImage: "star.fill")
                        .foregroundStyle(Color.sand)
                }
                .font(BT.footnote)
                .foregroundStyle(Color.inkMuted)
            }
            .padding(Spacing.md)
            .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .padding(.horizontal, Spacing.edge)
        .padding(.top, Spacing.md)
        .background(Color.canvas)
    }
}

// MARK: – PLACE CARD (horizontal scroll)

struct PlaceCard: View {
    let place: Place
    let index: Int

    private var cardColors: [Color] {
        let palettes: [[Color]] = [
            [Color(hex: "4A2820"), Color(hex: "6E3B2D")],
            [Color(hex: "3D2B1A"), Color(hex: "6B4226")],
            [Color(hex: "4A3D35"), Color(hex: "7A6558")],
            [Color(hex: "5C3E1A"), Color(hex: "8B6428")],
        ]
        return palettes[index % palettes.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                // Foto real si existe, gradiente como fallback
                if let coverUrl = place.coverUrl {
                    CachedImage(urlString: coverUrl) { img in
                        img.resizable().scaledToFill()
                    }
                    .frame(height: 110).clipped()
                } else {
                    LinearGradient(colors: cardColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 110)
                        .overlay { Text(place.stickerEmoji).font(.system(size: 40)) }
                }

                Text(place.category.label)
                    .font(BT.caption2)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.25))
                    .clipShape(Capsule())
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                if !place.description.isEmpty {
                    Text(place.description)
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(2)
                }
                Label("a 5 min", systemImage: "location.circle")
                    .font(BT.caption2)
                    .foregroundStyle(Color.teal)
                    .padding(.top, 2)
            }
            .padding(Spacing.sm)
        }
        .frame(width: 160)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .cardShadow()
    }
}

// MARK: – MAP PIN
// Quiet by default. Responds clearly on selection. No ambient pulsing.

struct PlacePin: View {
    let place: Place
    let isSelected: Bool

    var body: some View {
        ZStack {
            // Selection halo — only shown when active
            if isSelected {
                Circle()
                    .fill(Color.teal.opacity(0.12))
                    .frame(width: 64, height: 64)
            }

            Circle()
                .fill(isSelected ? Color.teal : Color.surface)
                .frame(
                    width: isSelected ? 48 : 40,
                    height: isSelected ? 48 : 40
                )
                .shadow(
                    color: .teal.opacity(isSelected ? 0.4 : 0.2),
                    radius: isSelected ? 12 : 6,
                    y: 3
                )
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? Color.clear : Color.teal.opacity(0.3),
                        lineWidth: 1.5
                    )
                )
                .overlay {
                    Image(systemName: place.stickerSymbol)
                        .font(.system(size: isSelected ? 20 : 15, weight: .light))
                        .foregroundStyle(isSelected ? Color.inkInverse : Color.teal)
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
    }
}

// MARK: – MAP CONTROL BUTTON
// Native material background — glass over the map content.

struct MapControlButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.teal)
                .frame(width: 44, height: 44)
        }
        .glassRounded(Radius.sm)
        .mapControlShadow()
    }
}
