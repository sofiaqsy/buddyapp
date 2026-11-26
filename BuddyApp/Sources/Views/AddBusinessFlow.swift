import SwiftUI
import CoreLocation

/// "Agrega tu negocio" en 3 pasos (Keyla, 21 Nov 2026: el alta se sentía pesada).
/// Reusa lo que la gente ya conoce:
///  1. ¿Dónde está? El mismo selector de "Agregar ubicación" (lugares cerca con
///     "Es mío", lugares del mapa sin dueño, el mapa). O "No tengo local fijo".
///     El lugar elegido llena el nombre y la ciudad.
///  2. ¿Qué ofreces? Nombre + las tarjetas de categoría de Inicio (con ícono).
///     La categoría empieza vacía: nadie queda como "Fincas" sin elegirlo.
///  3. ¿Cómo te contactan? WhatsApp con teclado numérico y la autorización.
/// Al crear, el negocio queda "En revisión" con su ubicación ya puesta.
struct AddBusinessFlow: View {
    var onDone: () -> Void

    enum Step: Int { case place = 1, offer, contact }
    @State private var step: Step = .place
    @State private var location: BusinessLocation? = nil
    @State private var noFixedPlace = false
    @State private var name = ""
    @State private var category: String? = nil
    @State private var city = ""
    @State private var contact = ""
    @State private var authorized = false
    @State private var busy = false
    @State private var errorText: String? = nil
    @State private var needsLogin = false
    @FocusState private var focus: Field?
    enum Field { case name, contact, city }

    static let categories = ["Fincas", "Tostadurías", "Cafeterías", "Restaurantes y comida local",
                             "Hospedaje", "Productos locales", "Artesanía y cultura",
                             "Guías y actividades", "Transporte con conductor"]

    var body: some View {
        VStack(spacing: 0) {
            header
            switch step {
            case .place: placeStep
            case .offer: offerStep
            case .contact: contactStep
            }
        }
        .background(Color.canvas)
        .navigationTitle("Agrega tu negocio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if step != .place {
                ToolbarItem(placement: .topBarLeading) {
                    ToolbarBackButton { goBack() }
                }
            }
        }
        .navigationBarBackButtonHidden(step != .place)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: Encabezado: paso y pregunta

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
        case .place: return "¿Dónde está tu negocio?"
        case .offer: return "¿Qué ofreces?"
        case .contact: return "¿Cómo te contactan?"
        }
    }

    // MARK: Paso 1: dónde

    private var placeStep: some View {
        VStack(spacing: 0) {
            BusinessLocationPicker(businessId: "", onPicked: { loc in
                location = loc
                noFixedPlace = false
                if name.trimmingCharacters(in: .whitespaces).isEmpty { name = loc.name }
                fillCity(from: loc)
                step = .offer
            })
            Button {
                Haptic.light()
                location = nil
                noFixedPlace = true
                if city.isEmpty { city = LocationService.current?.currentCity ?? "Villa Rica" }
                step = .offer
            } label: {
                Text("No tengo local fijo (vendo en casa, en ferias o por pedido)")
                    .font(BT.footnoteBold).foregroundStyle(Color.brand)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.edge)
            .padding(.bottom, 90)
        }
    }

    // MARK: Paso 2: qué

    private var offerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if let location {
                    placeChip(location.name)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nombre del negocio").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    TextField("Ej. Finca Las Orquídeas", text: $name)
                        .font(BT.callout)
                        .focused($focus, equals: .name)
                        .submitLabel(.done)
                        .padding(.horizontal, 16).frame(height: 50)
                        .background(Color.surface, in: Capsule())
                        .cardShadow()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Categoría").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    // Tarjetas de categoría (antes también en Inicio, quitadas el 23 Nov 2026).
                    CategoryPickerGrid(items: Self.categories.map { ($0, $0) }, main: $category,
                                       secondary: .constant([]), maxSecondary: 0)
                }
                primaryButton("Continuar", enabled: canContinueOffer) { step = .contact }
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var canContinueOffer: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 3 && category != nil
    }

    // MARK: Paso 3: contacto

    private var contactStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                summaryCard
                if noFixedPlace {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ciudad").font(BT.footnoteBold).foregroundStyle(Color.ink)
                        TextField("Ej. Villa Rica", text: $city)
                            .font(BT.callout).focused($focus, equals: .city)
                            .padding(.horizontal, 16).frame(height: 50)
                            .background(Color.surface, in: Capsule()).cardShadow()
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("WhatsApp del negocio").font(BT.footnoteBold).foregroundStyle(Color.ink)
                    TextField("Ej. 987 654 321", text: $contact)
                        .font(BT.callout)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .focused($focus, equals: .contact)
                        .padding(.horizontal, 16).frame(height: 50)
                        .background(Color.surface, in: Capsule())
                        .cardShadow()
                    Text("Los visitantes te escriben aquí. Puedes cambiarlo después.")
                        .font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
                // Consentimiento explícito (Ley 29733): una casilla clara junto al botón.
                Button { Haptic.light(); authorized.toggle() } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: authorized ? "checkmark.square.fill" : "square")
                            .font(.system(size: 22)).foregroundStyle(Color.brand)
                        Text("Autorizo que Buddy muestre mi negocio y mis productos a los visitantes.")
                            .font(BT.footnote).foregroundStyle(Color.ink).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(authorized ? [.isButton, .isSelected] : .isButton)

                if let errorText {
                    Text(errorText).font(BT.footnote).foregroundStyle(Color.errorRed)
                }
                if needsLogin {
                    NavigationLink(value: LinkBusinessRoute()) {
                        Text("Entrar con Apple o Google").font(BT.footnoteBold).foregroundStyle(Color.brand)
                            .frame(maxWidth: .infinity).frame(height: 48).background(Color.sageTint, in: Capsule())
                    }
                }
                primaryButton(busy ? "Creando…" : "Crear negocio", enabled: canCreate) { Task { await create() } }
                Text("Tu negocio quedará \"En revisión\". Mientras lo revisamos puedes completar tu perfil; cuando lo aprobemos podrás añadir productos.")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.top, Spacing.md)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private var canCreate: Bool {
        authorized && !busy && city.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// Lo elegido en los pasos anteriores, para revisar sin volver atrás.
    private var summaryCard: some View {
        HStack(spacing: 12) {
            CategoryIconBadge(category: category ?? "", diameter: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(BT.headline).foregroundStyle(Color.ink).lineLimit(1)
                Text([category, location?.address ?? (noFixedPlace ? "Sin local fijo" : nil), city.isEmpty ? nil : city]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(BT.caption1).foregroundStyle(Color.inkMuted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    // MARK: Piezas

    private func placeChip(_ text: String) -> some View {
        HStack(spacing: 6) {
            LocationPin(size: 13)
            Text(text).font(BT.footnoteBold).foregroundStyle(Color.ink).lineLimit(1)
            Button { step = .place } label: {
                Text("Cambiar").font(BT.caption1).foregroundStyle(Color.brand)
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(Color.surface, in: Capsule())
    }

    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(Color.inkInverse) }
                Text(title).font(BT.footnoteBold)
            }
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(enabled ? Color.brand : Color.inkMuted.opacity(0.2), in: Capsule())
            .foregroundStyle(enabled ? Color.inkInverse : Color.inkMuted)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func goBack() {
        focus = nil
        switch step {
        case .place: break
        case .offer: step = .place
        case .contact: step = .offer
        }
    }

    private func fillCity(from loc: BusinessLocation) {
        city = LocationService.current?.currentCity ?? "Villa Rica"
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: loc.lat, longitude: loc.lng)) { marks, _ in
            guard let m = marks?.first else { return }
            DispatchQueue.main.async {
                if let c = m.locality, !c.isEmpty { city = c }
                let street = [m.thoroughfare.map { t in m.subThoroughfare.map { "\(t) \($0)" } ?? t }, m.locality]
                    .compactMap { $0 }.joined(separator: ", ")
                if !street.isEmpty { location?.address = street }
            }
        }
    }

    // MARK: Crear (igual que antes: solicitud a la Cuenta negocio, queda en revisión)

    private func create() async {
        errorText = nil; needsLogin = false
        guard FincasAuth.hasSavedSession else {
            errorText = "Primero entra con tu cuenta de Apple o Google; así el negocio queda a tu nombre."
            needsLogin = true
            return
        }
        busy = true
        defer { busy = false }
        let n = name.trimmingCharacters(in: .whitespaces)
        let phone = contact.filter(\.isNumber)
        do {
            let token = try await FincasAuth.validIdToken()
            try await FincasAuth.requestBusiness(idToken: token, name: n, city: city.trimmingCharacters(in: .whitespaces),
                                                 phone: phone.isEmpty ? nil : phone)
            var b = ProtoBusiness(id: "pending-" + UUID().uuidString, name: n, category: category ?? "",
                                  contact: phone, pending: true)
            if let location { b.locations = [location] }
            AccountStore.shared.businesses.append(b)
            AccountStore.shared.activeBusinessId = b.id
            Haptic.success()
            onDone()
        } catch let e as FincasAuth.FincasError {
            if case .signIn = e { needsLogin = true }
            errorText = e.localizedDescription
        } catch {
            errorText = "No pudimos enviar la solicitud. Revisa tu conexión e intenta de nuevo."
        }
    }
}

/// La cuadrícula de categorías de "Agrega tu negocio" (paso 2), compartida con
/// Mi negocio > Información general (Keyla, 22 Nov 2026). El primer toque elige
/// la principal (borde lleno); los siguientes, hasta `maxSecondary` adicionales
/// (borde punteado). Tocar una elegida la quita.
struct CategoryPickerGrid: View {
    let items: [(id: String, name: String)]
    @Binding var main: String?
    @Binding var secondary: [String]
    var maxSecondary = 2

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(items, id: \.id) { item in card(item) }
        }
    }

    private func tap(_ id: String) {
        Haptic.light()
        if main == id {
            main = secondary.first
            if !secondary.isEmpty { secondary.removeFirst() }
        } else if secondary.contains(id) {
            secondary.removeAll { $0 == id }
        } else if main == nil || maxSecondary == 0 {
            main = id
        } else if secondary.count < maxSecondary {
            secondary.append(id)
        }
    }

    private func card(_ item: (id: String, name: String)) -> some View {
        let isMain = main == item.id
        let isSecondary = secondary.contains(item.id)
        return Button { tap(item.id) } label: {
            VStack(spacing: 8) {
                CategoryIconBadge(category: item.name, diameter: 40)
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .padding(.horizontal, 8)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isMain ? Color.brand : .clear, lineWidth: 2))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSecondary ? Color.brand : .clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(isMain ? "\(item.name), principal" : item.name)
        .accessibilityAddTraits(isMain || isSecondary ? [.isButton, .isSelected] : .isButton)
    }
}
