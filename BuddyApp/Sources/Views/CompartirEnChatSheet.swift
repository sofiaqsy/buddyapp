import SwiftUI

/// Elegir a quién mandarle un lugar recomendado.
///
/// La lista son las CONVERSACIONES que ya existen, no una agenda: Buddy no
/// tiene grafo de amigos, tiene matches. Compartir con alguien con quien nunca
/// hablaste sería empezar una conversación, que es otra decisión de producto y
/// otro flujo.
///
/// Una sola persona por envío. Selección múltiple es fácil de añadir después y
/// no aporta nada al primer día — mientras que sí obliga a decidir qué pasa si
/// dos de tres envíos fallan.
struct CompartirEnChatSheet: View {
    let card: ChatCard.Place

    @ObservedObject private var chatStore = ChatStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Imagen de la tarjeta, ya rasterizada. Se prepara al abrir la hoja para
    /// que tocar "Compartir fuera" no tenga que esperar a la descarga.
    @State private var imagenTarjeta: UIImage? = nil
    @State private var preparandoImagen = false

    @State private var enviandoA: String? = nil
    @State private var enviadoA: Set<String> = []
    @State private var fallo = false

    /// Solo conversaciones VIVAS.
    ///
    /// `chatStore.connections` trae todos los matches, y los terminados son la
    /// mayoría: gente a la que ayudaste una vez hace meses. Ofrecerlos como
    /// destino era listar a veintitantas personas con las que no hay ninguna
    /// conversación abierta.
    ///
    /// Y un chat completado es de solo lectura (ver `closedBar`): el mensaje
    /// llegaría a un sitio donde nadie puede contestar. Mandar algo a un buzón
    /// mudo es peor que no ofrecer el destino.
    ///
    /// Mismo criterio que la sección "activas" del tab Conexiones — si esa
    /// regla cambia, tiene que cambiar en los dos sitios a la vez.
    private var conversaciones: [ChatStore.ConnectionItem] {
        chatStore.connections.filter {
            ["pending", "accepted", "active"].contains($0.match.status)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if conversaciones.isEmpty {
                    vacio
                } else {
                    lista
                }
            }
            // TEMPORAL — quitar antes de publicar. Dice cuántas conexiones hay
            // y en qué estado, para poder distinguir "no tienes conversaciones"
            // de "el filtro se comió las que sí tenías".
            .onAppear {
                let porEstado = Dictionary(grouping: chatStore.connections) {
                    $0.match.status ?? "nil"
                }.mapValues(\.count)
                print("📤 [CompartirEnChat] conexiones=\(chatStore.connections.count) por estado=\(porEstado) → se ofrecen \(conversaciones.count)")
            }
            // Se prepara mientras el usuario lee la lista, para que el botón no
            // se quede pensando cuando lo toque.
            .task { imagenTarjeta = await construirImagen() }
            .background(Color.canvas)
            .navigationTitle("Compartir lugar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("No pudimos enviarlo", isPresented: $fallo) {
            Button("Entendido", role: .cancel) {}
        } message: {
            Text("Revisa tu conexión e inténtalo de nuevo.")
        }
    }

    private var lista: some View {
        ScrollView {
            VStack(spacing: 0) {
                encabezado

                ForEach(conversaciones) { conn in
                    Button {
                        enviar(a: conn)
                    } label: {
                        fila(conn)
                    }
                    .buttonStyle(.plain)
                    .disabled(enviandoA != nil || enviadoA.contains(conn.id))

                    Divider().padding(.leading, 68)
                }

                salirDeBuddy
            }
        }
    }

    private var encabezado: some View {
        HStack(spacing: 12) {
            if let url = card.photoUrl {
                CachedImage(urlString: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color.sandLight)
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                if let cat = card.category, !cat.isEmpty {
                    Text(cat).font(BT.caption1).foregroundStyle(Color.inkMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, Spacing.md)
    }

    private func fila(_ conn: ChatStore.ConnectionItem) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.surfaceRaised)
                .frame(width: 40, height: 40)
                .overlay {
                    if let urlStr = conn.buddyAvatarUrl, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color.surfaceRaised }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.inkMuted)
                    }
                }

            Text(conn.buddyName)
                .font(BT.footnote)
                .foregroundStyle(Color.ink)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Enviado se queda marcado en vez de cerrar la hoja: así se puede
            // mandar a varias personas seguidas sin volver a abrirla, y queda
            // claro a quién ya se le mandó.
            if enviadoA.contains(conn.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.onlineGreen)
            } else if enviandoA == conn.id {
                ProgressView().scaleEffect(0.8)
            } else {
                Text("Enviar")
                    .font(BT.caption1.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
        }
        .padding(.horizontal, Spacing.edge)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .opacity(enviadoA.contains(conn.id) ? 0.6 : 1)
    }

    /// WhatsApp, Mensajes, Notas… lo que el sistema ofrezca.
    private var salirDeBuddy: some View {
        Button {
            compartirFuera()
        } label: {
            HStack(spacing: 12) {
                if preparandoImagen {
                    ProgressView().scaleEffect(0.8).frame(width: 40)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.ink)
                        .frame(width: 40)
                }
                Text("Compartir fuera de Buddy")
                    .font(BT.footnote)
                    .foregroundStyle(Color.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.edge)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(preparandoImagen)
        .padding(.top, Spacing.sm)
    }

    /// Fuera de Buddy se manda la MISMA tarjeta, como imagen, más el texto.
    ///
    /// Antes salía solo texto y en WhatsApp llegaba un renglón suelto: el lugar
    /// se comparte porque se ve bien, y una frase no enseña nada. Se rasteriza
    /// la tarjeta con ImageRenderer para que lo que sale de la app se parezca a
    /// lo que se ve dentro.
    ///
    /// UIActivityViewController y no ShareLink porque hay que mandar DOS cosas
    /// —imagen y texto— y ShareLink solo acepta items del mismo tipo. Se
    /// presenta desde el controlador de más arriba SIN cerrar esta hoja: cerrar
    /// y presentar a la vez era la carrera que dejaba el botón muerto.
    private func compartirFuera() {
        guard !preparandoImagen else { return }
        preparandoImagen = true
        Task {
            let imagen: UIImage?
            if let ya = imagenTarjeta { imagen = ya } else { imagen = await construirImagen() }
            await MainActor.run {
                imagenTarjeta = imagen
                preparandoImagen = false
                var items: [Any] = []
                if let imagen { items.append(imagen) }
                items.append(textoParaFuera)
                presentarHojaDelSistema(items)
            }
        }
    }

    /// Descarga la foto y pinta la tarjeta en un UIImage.
    ///
    /// Sin foto no se rasteriza nada: una tarjeta con un hueco gris es peor que
    /// el texto solo, y el texto siempre viaja.
    private func construirImagen() async -> UIImage? {
        guard let urlStr = card.photoUrl, let url = URL(string: urlStr) else { return nil }
        guard let foto = await ImageCache.shared.load(url) else {
            print("📤 [CompartirEnChat] sin foto para la tarjeta — se comparte solo texto")
            return nil
        }
        return await MainActor.run { () -> UIImage? in
            let render = ImageRenderer(content: TarjetaParaCompartir(card: card, foto: foto))
            // 3x: la imagen se ve en la galería de otra persona, a pantalla
            // completa. A 1x el texto sale borroso.
            render.scale = 3
            return render.uiImage
        }
    }

    private func presentarHojaDelSistema(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return }
        // El de más arriba: esta hoja sigue presentada, así que presentar desde
        // la raíz lanzaría "already presenting" y no aparecería nada.
        var arriba = root
        while let siguiente = arriba.presentedViewController { arriba = siguiente }
        let av = UIActivityViewController(activityItems: items, applicationActivities: nil)
        av.popoverPresentationController?.sourceView = arriba.view
        arriba.present(av, animated: true)
    }

    /// Lo que sale de la app, junto a la imagen de la tarjeta.
    ///
    /// Nombra a la PERSONA, no a la app. Quien comparte no descubrió el lugar:
    /// lo descubrió Angie, y que alguien real lo recomiende es todo el valor
    /// del mensaje. "Encontré este lugar en Buddy" se lleva un crédito que no
    /// le toca y debilita justo lo que hace fuerte a la recomendación.
    private var textoParaFuera: String {
        let autor = card.authorName?.components(separatedBy: " ").first?
            .trimmingCharacters(in: .whitespaces)
        let presentacion = (autor?.isEmpty == false)
            ? "\(autor!) recomendó este lugar en Buddy. Míralo aquí:"
            : "Un buddy recomendó este lugar. Míralo aquí:"
        return "📍 \(card.name)\n\(presentacion)\n\(enlacePublico)"
    }

    /// Universal Link del lugar. Con Buddy instalado abre la ficha; sin ella,
    /// la página pública. El destino viaja como `d` para que la app pueda
    /// cargar la guía correcta sin una consulta extra.
    private var enlacePublico: String {
        var url = "\(APIClient.shared.publicBaseURL)/place/\(card.spotId)"
        if let dest = card.destinationId { url += "?d=\(dest)" }
        return url
    }

    private var vacio: some View {
        VStack(spacing: Spacing.sm) {
            Text("No tienes conversaciones abiertas")
                .font(BT.callout)
                .foregroundStyle(Color.ink)
            // Nombra el porqué: con apoyos terminados a la espalda, un "todavía
            // no tienes conversaciones" se leería como que la app perdió algo.
            Text("Los apoyos ya cerrados no admiten mensajes nuevos. Cuando tengas una conversación en curso podrás compartirle lugares desde aquí.")
                .font(BT.footnote)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
            Button {
                compartirFuera()
            } label: {
                Text(preparandoImagen ? "Preparando…" : "Compartir fuera de Buddy")
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, 10)
                    .background(Color.surface)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(preparandoImagen)
            .padding(.top, Spacing.sm)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func enviar(a conn: ChatStore.ConnectionItem) {
        guard enviandoA == nil, !enviadoA.contains(conn.id) else { return }
        guard let content = ChatCard.encode(card) else {
            fallo = true
            return
        }
        Haptic.light()
        enviandoA = conn.id
        Task {
            do {
                _ = try await APIClient.shared.sendMessage(matchId: conn.match.id, content: content)
                await MainActor.run {
                    enviandoA = nil
                    enviadoA.insert(conn.id)
                    Haptic.success()
                }
            } catch {
                print("❌ [CompartirEnChat] no se pudo enviar: \(error)")
                await MainActor.run {
                    enviandoA = nil
                    fallo = true
                }
            }
        }
    }
}

/// La tarjeta tal como sale de la app, para rasterizarla con ImageRenderer.
///
/// No reutiliza la del chat a propósito: aquella vive dentro de una burbuja,
/// mide 240pt y hereda el fondo de la conversación. Esta se ve sola, en la
/// galería de otra persona y sin nada alrededor, así que necesita su propio
/// respiro y el nombre de Buddy — fuera de la app nadie sabe de dónde salió.
///
/// Medidas fijas y no relativas: no hay pantalla que la contenga cuando se
/// dibuja, así que un layout que dependa del ancho disponible saldría a cero.
private struct TarjetaParaCompartir: View {
    let card: ChatCard.Place
    let foto: UIImage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(uiImage: foto)
                .resizable()
                .scaledToFill()
                .frame(width: 320, height: 320)
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                if let cat = card.category, !cat.isEmpty {
                    Text(cat.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Color.inkMuted)
                }
                Text(card.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let autor = card.authorName?.components(separatedBy: " ").first,
                   !autor.isEmpty {
                    Text("Recomendado por \(autor)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(1)
                }

                // La firma: fuera de la app, esto es lo único que dice de dónde
                // viene la recomendación. Va el icono real y no un símbolo del
                // sistema — un pin genérico no identifica a nadie, y esta
                // imagen acaba en la galería de gente que todavía no conoce la
                // app.
                HStack(spacing: 6) {
                    Image("AppIconImage")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    Text("BuddyApp")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.brand)
                }
                .padding(.top, 6)
            }
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
        .frame(width: 320)
        .background(Color.surface)
    }
}
