import SwiftUI
import CoreLocation
import UIKit

// MARK: – INICIO
// Calm, trustworthy dashboard. The user's home base between adventures.

/// Desde dónde se construye el próximo Help Request en el composer de Home.
/// Lo decide el GPS (ver effectiveHomeContext); .trip solo queda como reserva
/// para cuando no hay ubicación resuelta, y lleva el journey.id porque puede
/// haber más de un trip vivo.
enum HomeContext: Equatable {
    case currentLocation
    case trip(String)
}

struct InicioView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var routeStore: RouteStore
    @EnvironmentObject var locationService: LocationService
    @State private var navPath = NavigationPath()
    @State private var showPendingContactSheet  = false
    @State private var isFindingBuddy           = false   // creando/reusando trip en background
    @State private var isActivatingNextTrip     = false   // evita doble-tap en "Activar" siguiente viaje
    @State private var homeBuddyCount           = 0
    @State private var homeCommunityContext: APIPlaceContext? = nil
    @State private var homeHelpSeed: (category: String, description: String?)? = nil  // categoría elegida en Home
    @State private var confirmedHelpSeed: (category: String, description: String?)? = nil  // seed confirmado para la sheet
    /// Drives the home-help sheet. Non-nil = sheet open. Atom­ically carries
    /// both destinationId and the optional seed so SwiftUI never renders the
    /// sheet content with a nil destination (avoids blank-screen race).
    @State private var homeHelpSheet: HomeHelpItem? = nil
    /// Resolución de ubicación del backend (LocationResolver: polígono → radio).
    /// Única fuente de verdad para "Estás en X" y el destino del CTA del Home.
    /// Reemplaza al viejo nearestDestination (5 destacados + radio 50 km), que
    /// podía elegir un destino vecino equivocado (ej: La Merced estando en Villa Rica).
    @State private var resolvedLocation: APILocationResolution? = nil
    /// Buddy cuyo perfil se está mirando desde "Comunidad viva".
    @State private var pulseProfileTarget: PulseProfileTarget? = nil
    @State private var destinations: [APIDestination] = []
    @State private var pendingJourney: APIJourney? = nil
    @State private var activeJourney: APIJourney? = nil
    @State private var liveJourneys: [APIJourney] = []   // active + planning, para swipe
    @State private var currentTripPage = 0
    @State private var activeMatch: APIMatch? = nil
    /// Solicitud propia todavía sin buddy. Es el otro estado que el Home tiene
    /// que saber contar: no hay match que mostrar, pero hay algo en curso y
    /// abandonar la pantalla no lo cancela. Sin esto el Home se dibuja como si
    /// el viajero no hubiera pedido nada.
    @State private var openRequest: APIHelpRequest? = nil
    @State private var pioneerConfirmation: String? = nil   // banner tras auto-crear request en lugar sin buddies
    /// Chat abierto desde la card "Tu buddy asignado" (paridad con Android).
    @State private var homeChatTarget: ChatStore.ConnectionItem? = nil
    @State private var showPublishSuccessToast = false
    @State private var isLoadingData = true
    @State private var loadDataFailed = false
    @State private var loadDataTask: Task<Void, Never>? = nil
    @State private var refreshStateTask: Task<Void, Never>? = nil
    /// Carrusel de spots. Vive en SpotsStore: una sola petición, cache en disco
    /// y un fallo nunca vacía la lista buena.
    @ObservedObject private var spotsStore = SpotsStore.shared
    /// Foto del carrusel en zoom: mientras dura, el Home no scrollea.
    @ObservedObject private var carouselZoom = CarouselZoomState.shared
    private var exploreCards: [APIPlaceCard] { spotsStore.spots }
    @State private var recentHelp: [APIRecentHelp] = []   // comunidad viva (destino activo)
    @State private var communityPulse: [APIPulseItem] = [] // pulso global (fallback sin actividad local)
    @State private var recentHelpByDest: [String: [APIRecentHelp]] = [:]  // por cada trip vivo
    @State private var isLoadingRecentHelp = false        // anti re-entrada
    @State private var recentHelpDestId: String? = nil    // último destino cargado
    @State private var recentHelpLoadedAt: Date? = nil    // throttle de refetch
    /// Sube con cada re-tap del tab Inicio: el composer lo lee para rehacer el
    /// orden de las recomendaciones (ver reshuffleToken).
    @State private var reshuffleToken = 0
    @State private var lastLoadDataAt: Date? = nil
    @State private var lastRefreshTripStateAt: Date? = nil // throttle scenePhase refresh (30s)
    @State private var lastCommunityContextLocation: CLLocation? = nil // gate GPS → resolve
    @State private var lastCommunityContextAt: Date? = nil
    /// Aviso "Ahora en X" cuando el destino resuelto CAMBIA. Sin esto el
    /// contenido se reemplazaba solo y parecía un fallo, no una reacción.
    @State private var locationChangeMessage: String? = nil
    @State private var showLocationChangeToast = false
    /// Coordenadas y momento de la última resolución REAL contra el backend.
    @State private var lastResolveLocation: CLLocation? = nil
    @State private var lastResolveAt: Date? = nil

    /// Cuánto hay que moverse para volver a preguntar. 150 m distingue
    /// "cambié de zona" del ruido del GPS urbano (rebotes de 20-50 m entre
    /// edificios) sin esperar a que cruces medio pueblo.
    /// Cuánto hay que moverse para volver a preguntarlo TODO: destino
    /// resuelto y spots del carrusel. 150 m distingue "me moví" del ruido del
    /// GPS urbano (rebotes de 20-50 m entre edificios).
    ///
    /// Un solo umbral y no dos. Antes los spots usaban 500 m, con el
    /// razonamiento de que "cambian más despacio que el destino". Es al revés:
    /// el destino (Breña) es el mismo durante kilómetros, mientras que el
    /// lugar más cercano cambia en decenas de metros — con El encanto a 37 m y
    /// Cafetería Rosal a 75 m, caminar una cuadra ya cambia cuál va primero.
    /// Con umbrales distintos el Home quedaba a medias: la ubicación se
    /// actualizaba y el carrusel se quedaba en la lista de la esquina anterior.
    private static let locationRefreshMeters: CLLocationDistance = 150

    @State private var communityPulseLoadedAt: Date? = nil
    @State private var pendingNavToDetail = false
    @State private var hasLoaded = false
    @State private var showActivateNextTripAlert = false
    @State private var skipNextRefresh = false
    @ObservedObject private var chatStore = ChatStore.shared
    @ObservedObject private var placeDeepLink = PlaceDeepLink.shared
    @EnvironmentObject private var authState: AuthState
    @EnvironmentObject private var router: AppRouter
    /// IdentitySheet para el flujo de registro progresivo
    @State private var showIdentitySheet = false
    /// Acción pendiente que se ejecuta después de que el usuario se autentique
    @State private var pendingIdentityAction: (() -> Void)? = nil
    /// Journey activo en el sheet de contacto — presentar con .sheet(item:) elimina el race con isPresented.
    @State private var contactSheetJourney: APIJourney? = nil
    /// Copia del journey para el onDismiss (item ya es nil cuando onDismiss dispara).
    @State private var lastContactSheetJourney: APIJourney? = nil

    private var pendingReply: Bool {
        chatStore.connections
            .first { ["accepted","active"].contains($0.match.status) }?
            .pendingReply ?? false
    }

    // Firma del estado de matches del viajero — cambia cuando un buddy acepta o
    // se cierra un apoyo. Dispara la actualización en vivo del card.
    private var travelerMatchSignature: String {
        chatStore.connections
            .filter { !$0.isBuddyRole }
            .map { "\($0.match.id):\($0.match.status)" }
            .sorted()
            .joined(separator: "|")
    }

    // Prueba social: nombre del último buddy que ayudó en este destino
    private var recentHelperFirstName: String? {
        guard let full = recentHelp.first?.buddy?.fullName else { return nil }
        return full.components(separatedBy: " ").first?.capitalized
    }

    // Destino activo. Ya NO decide el feed de historias: la ubicación manda y el
    // destino queda como etiqueta. Se conserva para quien lo siga necesitando.
    private var myDestinationId: String? {
        let j = activeJourney ?? pendingJourney
        return j?.destination?.id ?? j?.destinationId
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            scrollContent
        }
        .overlay(alignment: .bottom) {
            if let msg = pioneerConfirmation {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.brand)
                    Text(msg)
                        .font(BT.footnote)
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Button { withAnimation { pioneerConfirmation = nil } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.inkMuted)
                    }
                }
                .padding(Spacing.md)
                .background(Color.sandLight)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .padding(.horizontal, Spacing.edge)
                .padding(.bottom, Spacing.md)
                .safeAreaPadding(.bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        withAnimation { pioneerConfirmation = nil }
                    }
                }
            }
        }
        .toast(isPresented: $showPublishSuccessToast, message: "¡Historia publicada!")
        // El Home siguiendo al viajero tiene que NOTARSE. Sin este aviso el
        // contenido se reemplaza solo y se lee como un fallo de carga.
        .toast(isPresented: $showLocationChangeToast, message: locationChangeMessage ?? "")
        .onReceive(NotificationCenter.default.publisher(for: .journeyActivated)) { _ in
            navPath = NavigationPath()
            pendingNavToDetail = true
            Task { await quickLoadForDetail() }
        }
        .onChange(of: routeStore.isReady) { _, ready in
            guard ready, pendingNavToDetail, activeJourney != nil else { return }
            pendingNavToDetail = false
            router.switchTo(.inicio)
            navPath.append("tripDetail")
        }
        .sheet(item: $contactSheetJourney, onDismiss: {
            confirmedHelpSeed = nil
            // Optimistic: si ya tenemos un journey capturado (puede ser planning)
            // mostrarlo de inmediato; refreshTripState lo confirmará con el status real.
            if activeJourney == nil, let j = lastContactSheetJourney {
                activeJourney = j
                liveJourneys  = [j]
            }
            lastContactSheetJourney = nil
            Task { await refreshTripState() }
        }) { journey in
            let _ = print("🟡 [sheet:contact] render — journey=\(journey.id)")
            ContactarBuddyView(
                journey: journey,
                initialRequest: confirmedHelpSeed,
                onCancelled: {
                    // Usuario canceló sin aceptar buddy → cancelar el journey
                    let jid = journey.id
                    Task {
                        try? await APIClient.shared.updateJourneyStatus(journeyId: jid, status: "cancelled")
                    }
                    activeJourney  = nil
                    pendingJourney = nil
                    liveJourneys   = []
                    contactSheetJourney = nil
                }
            )
        }
        // Flujo de la Home SIN trip previo: se pide ayuda solo con el destino.
        // El Trip se crea recién cuando un buddy ACEPTA (backend). Si se cancela
        // y nadie acepta, no queda ningún trip huérfano.
        .sheet(item: $homeHelpSheet, onDismiss: {
            homeHelpSeed = nil
            Task { await refreshTripState() }
        }) { item in
            let destName = item.journey?.destination?.name ?? resolvedLocation?.destinationName
            ContactarBuddyView(
                journey: item.journey,
                destinationId: item.destinationId,
                destinationName: destName,
                initialRequest: item.seed,
                startsConversation: item.startsConversation
            )
        }
        .sheet(isPresented: $showPendingContactSheet) {
            let _ = print("🟡 [sheet:pending] render — pendingJourney=\(pendingJourney?.id ?? "nil")")
            if let journey = pendingJourney {
                ContactarBuddyView(journey: journey, preselectedCategory: "transport")
            }
        }
        // Chat desde la card "Tu buddy asignado" — mismo patrón que Conexiones
        .sheet(item: $homeChatTarget, onDismiss: {
            Task { await chatStore.load(); await refreshTripState() }
        }) { item in
            if let journey = SyntheticJourney.make(for: item.match) {
                BuddyChatView(match: item.match, journey: journey).equatable()
            }
        }
        // GPS cambió → re-resolver ubicación y recargar los spots de la zona.
        .onChange(of: locationService.userLocation) { _, loc in
            // CLLocation es clase: cada fix del GPS es instancia nueva aunque el
            // usuario no se haya movido, así que este onChange dispara en cada
            // tick. El gate es por DISTANCIA: antes tenía además `|| age > 60`,
            // que golpeaba el backend cada minuto aunque el viajero estuviera
            // quieto, y aun así no reaccionaba antes cuando se movía de verdad.
            // Lo único que justifica repetir por tiempo es no tener todavía una
            // resolución — ahí sí conviene reintentar.
            guard let loc else { return }

            // EN CADA FIX, sin puerta: reordenar los spots que ya están en
            // memoria. El carrusel tiene las coordenadas de cada lugar, así
            // que saber cuál queda más cerca ahora no necesita red. Esto es lo
            // que hace que la lista se mueva CONTIGO en vez de a saltos: entre
            // Cafetería Rosal (14 m) y El encanto (54 m) media cuadra ya cambia
            // el orden, y esperar a la siguiente petición para reflejarlo hacía
            // que pareciera que el Home no se entera.
            if let estable = locationService.stableLocation {
                resortSpots(from: estable)
            }

            // La RED sí va con puerta. CLLocation es clase: cada fix es una
            // instancia nueva aunque no te muevas, así que sin esto habría una
            // petición por tick.
            let moved = lastCommunityContextLocation.map { loc.distance(from: $0) } ?? .greatestFiniteMagnitude
            let age   = Date().timeIntervalSince(lastCommunityContextAt ?? .distantPast)
            let needsRetry = resolvedLocation == nil && age > 30
            guard moved > Self.locationRefreshMeters || needsRetry else { return }
            // Ojo con Int(moved): sin consulta previa, `moved` es
            // .greatestFiniteMagnitude y convertirlo a Int NO devuelve un
            // número grande, aborta el proceso. Solo se formatea cuando hay
            // una distancia real que contar.
            let desde = lastCommunityContextLocation == nil ? "primer fix" : "\(Int(moved))m"
            dlog("🏠 [gps] \(desde) desde la última consulta → refresco ubicación + spots")
            lastCommunityContextLocation = loc
            lastCommunityContextAt = Date()
            Task { await refreshHomeCommunityContext() }

            // Refetch: puede haber spots nuevos que antes quedaban fuera del
            // radio de la consulta. El reorden de arriba solo mueve los que ya
            // tenemos; esto trae los que aún no conocemos.
            Task { await refreshSpotsForLocation() }
        }
        .onChange(of: authState.isLoggedIn) { _, loggedIn in
            if !loggedIn {
                pendingJourney = nil
                activeJourney  = nil
                liveJourneys   = []
                activeMatch    = nil
                recentHelp     = []
                recentHelpByDest = [:]
                pendingIdentityAction = nil
                hasLoaded = false
            } else {
                Task { await loadData() }
            }
        }
        // Registro progresivo: se muestra cuando una acción requiere identidad
        .sheet(isPresented: $showIdentitySheet, onDismiss: {
            // Si el usuario cerró sin autenticarse, descarta la acción pendiente
            if !authState.isLoggedIn { pendingIdentityAction = nil }
        }) {
            IdentitySheet(purpose: .buddy) {
                // Autenticado: ejecutar la acción que estaba esperando
                pendingIdentityAction?()
                pendingIdentityAction = nil
            }
            .environmentObject(authState)
        }
        // location prompt is rendered inline above the trip card — no alert needed
    }

    // MARK: – Registro progresivo

    /// Ejecuta `action` si el usuario tiene sesión, o muestra el IdentitySheet primero.
    private func requireIdentity(context: String? = nil, then action: @escaping () -> Void) {
        if authState.canRequestHelp {
            action()
        } else {
            pendingIdentityAction = action
            showIdentitySheet = true
        }
    }

    // MARK: – Contexto del Home

    /// "Ubicación actual" disponible = el backend resolvió un destino real para el GPS.
    private var hasCurrentLocationContext: Bool { resolvedLocation != nil }

    /// Contexto del composer. El GPS MANDA: si el backend resolvió un destino
    /// para donde estás, ese es el contexto, haya o no trips vivos.
    ///
    /// Antes había un selector para elegir entre "Ubicación actual" y cada
    /// trip vivo. Se quitó: con el GPS resolviendo bien, el selector aparecía
    /// en cuanto tenías un trip en otra ciudad —un combo encima de "Consulta
    /// con un buddy" para una decisión que el viajero no había pedido tomar.
    /// Dónde estás no es ambiguo, y la app tiene esa información.
    ///
    ///   GPS resuelto        → Ubicación actual
    ///   sin GPS + trip(s)   → el primer trip vivo (mejor eso que nada)
    ///   sin GPS + sin trip  → nil (flujo de permisos/registro existente)
    private var effectiveHomeContext: HomeContext? {
        if hasCurrentLocationContext { return .currentLocation }
        if let first = liveJourneys.first { return .trip(first.id) }
        return nil
    }

    /// El journey correspondiente al contexto efectivo, si es de tipo .trip.
    private var effectiveTripJourney: APIJourney? {
        guard case .trip(let jid) = effectiveHomeContext else { return nil }
        return liveJourneys.first { $0.id == jid }
    }

    /// true cuando homeComposer va a pintar algo ARRIBA de CategoryPickerView
    /// (el selector, o locationContext en Case 4). CategoryPickerView ya trae
    /// su propio Spacing.md antes del heading — sin esta bandera, el
    /// contenedor exterior sumaba OTRO Spacing.md incluso cuando no hay nada
    /// que separar (Case 3: sin selector, sin locationContext), dejando un
    /// espacio doble e injustificado encima de "Consulta con un buddy".
    private var homeComposerHasHeaderRow: Bool {
        effectiveHomeContext == nil
    }

    // MARK: – Contexto de ubicación

    /// Muestra "ESTÁS EN {ciudad}" si hay ubicación; si no, ofrece activarla.
    /// Si la ubicación YA está concedida pero el usuario no está cerca de ningún
    /// destino conocido, no mostramos nada (el botón sería engañoso: ya está activa).
    @ViewBuilder
    private var locationContext: some View {
        let authorized = locationService.authorizationStatus == .authorizedWhenInUse ||
                         locationService.authorizationStatus == .authorizedAlways
        let displayCity = resolvedLocation?.destinationName ?? locationService.currentCity
        if let city = displayCity {
            HStack(spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Estás en \(city)")
                    .font(BT.caption1.weight(.semibold))
            }
            .foregroundStyle(Color.brand)
        } else if !authorized {
            Button {
                Haptic.light()
                switch locationService.authorizationStatus {
                case .denied, .restricted:
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                default:
                    locationService.requestPermission()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "location.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Activa tu ubicación para conectarte con ayuda cerca")
                        .font(BT.caption1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.brand.opacity(0.5))
                }
                .foregroundStyle(Color.brand)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: – Find a Buddy (trip automático)

    /// Destino conocido más cercano a la ubicación actual, dentro de su radio.
    /// nil si no hay GPS o estás fuera de cobertura de cualquier destino.
    /// CTA principal: el usuario toca "Buscar un buddy" sin crear un trip a mano.
    /// El destino viene del LocationResolver del backend (resolvedLocation) —
    /// nunca de la lista de destacados. Si no hay resolución, flujo pioneer.
    private func findABuddy() async {
        if let resolved = resolvedLocation {
            await openHelp(forDestinationId: resolved.destinationId)
        } else if let loc = locationService.userLocation {
            await pioneerHelpFlow(category: "general", description: nil, loc: loc)
        } else {
            navPath.append("register")
        }
    }

    /// Flujo pioneer: el lugar no tiene buddies ni destino registrado.
    /// Crea el Journey (GPS → place) y la Request en silencio, luego muestra
    /// un banner de confirmación. El usuario aprende un único botón.
    private func pioneerHelpFlow(category: String, description: String?, loc: CLLocation) async {
        do {
            let journey  = try await APIClient.shared.ensureActiveTripForGPS(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
            let _        = try await APIClient.shared.createHelpRequestForJourney(journeyId: journey.id, category: category, description: description)
            let city     = locationService.currentCity ?? "tu zona"
            await MainActor.run {
                withAnimation { pioneerConfirmation = "Registramos tu solicitud en \(city). Te avisaremos cuando haya un buddy disponible." }
                // Navigate to Tu trip tab after creating request
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    router.switchTo(.trips)
                }
            }
        } catch {
            print("❌ [pioneerHelpFlow] error: \(error)")
            await MainActor.run { navPath.append("register") }
        }
    }

    /// Pioneer CON destino resuelto (0 buddies): el trip se crea automático
    /// para ese destino + la solicitud, banner y a "Tu trip" — mismas reglas
    /// que pioneerRegister en Android. No hay nada que "buscar" sin buddies.
    private func pioneerHelpFlow(category: String, description: String?, destinationId: String, cityName: String?) async {
        do {
            let journey = try await APIClient.shared.ensureActiveTrip(destinationId: destinationId)
            let _       = try await APIClient.shared.createHelpRequestForJourney(journeyId: journey.id, category: category, description: description)
            let city    = cityName ?? locationService.currentCity ?? "tu zona"
            await MainActor.run {
                withAnimation { pioneerConfirmation = "Registramos tu solicitud en \(city). Te avisaremos cuando haya un buddy disponible." }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    router.switchTo(.trips)
                }
            }
        } catch {
            print("❌ [pioneerHelpFlow dest] error: \(error)")
            await MainActor.run { navPath.append("register") }
        }
    }

    /// El CTA "Consultar en {ciudad}" del carrusel. No dispara una búsqueda:
    /// abre la conversación. Reutiliza la misma resolución de destino que el
    /// resto del Home (trip elegido → GPS resuelto) para no duplicar reglas.
    private func startConversationFromHome() {
        requireIdentity {
            guard !isFindingBuddy else { return }
            if let trip = effectiveTripJourney,
               let destId = trip.destination?.id ?? trip.destinationId {
                homeHelpSheet = HomeHelpItem(destinationId: destId, seed: nil,
                                             journey: trip, startsConversation: true)
                return
            }
            guard let dest = resolvedLocation else {
                print("🔵 [startConversationFromHome] sin destino resuelto → registro")
                navPath.append("register")
                return
            }
            print("🔵 [startConversationFromHome] destId=\(dest.destinationId)")
            homeHelpSheet = HomeHelpItem(destinationId: dest.destinationId, seed: nil,
                                         startsConversation: true)
        }
    }

    /// Abre el flujo de ayuda para un destino — SIN crear trip todavía.
    /// El trip se crea recién cuando un buddy acepta.
    private func openHelp(forDestinationId destId: String) async {
        await MainActor.run {
            print("🔵 [openHelp] destId=\(destId)")
            homeHelpSeed = nil
            homeHelpSheet = HomeHelpItem(destinationId: destId, seed: nil)
        }
    }

    /// El usuario eligió categoría/texto DIRECTO en la Home → abre el flujo de
    /// ayuda ya en "buscando" SIN crear trip (se crea al aceptar un buddy).
    private func submitHelpFromHome(category: String, description: String?) async {
        // Un trip elegido explícitamente (selector de contexto) → usar ESE trip,
        // igual que siempre. Con "Ubicación actual" elegida cae al branch de abajo
        // aunque haya un trip vivo — el contexto lo decide el usuario, nunca el GPS
        // en silencio.
        if let activeJourney = effectiveTripJourney {
            // Pioneer: no hay buddies en este lugar → redirigir al tab Tu trip
            if homeCommunityContext?.totalBuddies == 0 {
                dlog("📍 [submitHelpFromHome] pioneer con trip activo → Tu trip tab")
                await MainActor.run { router.switchTo(.trips) }
                return
            }
            let destIdOpt = activeJourney.destination?.id ?? activeJourney.destinationId
            if let destId = destIdOpt {
                await MainActor.run {
                    homeHelpSheet = HomeHelpItem(
                        destinationId: destId,
                        seed: (category, description),
                        journey: activeJourney
                    )
                }
                return
            }
        }
        // Pioneer con destino resuelto pero SIN buddies: no hay nada que
        // "buscar" — el trip + solicitud se crean automáticamente y se navega
        // a Tu trip (misma regla que Android: pioneerRegister con destino).
        if homeCommunityContext?.totalBuddies == 0, let dest = resolvedLocation {
            dlog("📍 [submitHelpFromHome] pioneer con destino \(dest.destinationName) → crear trip automático")
            await pioneerHelpFlow(category: category, description: description,
                                  destinationId: dest.destinationId, cityName: dest.destinationName)
            return
        }
        // El destino del CTA es el resuelto por el backend — mismo lugar que el
        // usuario ve en "Estás en X" y en el contador de buddies.
        guard let dest = resolvedLocation else {
            if let loc = locationService.userLocation, homeCommunityContext?.totalBuddies == 0 {
                // Pioneer sin trip: crear el trip + request, luego ir a Tu trip
                dlog("📍 [submitHelpFromHome] pioneer sin trip + cat=\(category) → crear trip + Tu trip tab")
                await pioneerHelpFlow(category: category, description: description, loc: loc)
                await MainActor.run { router.switchTo(.trips) }
            } else if let loc = locationService.userLocation, homeCommunityContext != nil {
                await pioneerHelpFlow(category: category, description: description, loc: loc)
            } else {
                await MainActor.run {
                    homeHelpSeed = (category, description)
                    navPath.append("register")
                }
            }
            return
        }
        await MainActor.run {
            homeHelpSeed  = (category, description)
            homeHelpSheet = HomeHelpItem(destinationId: dest.destinationId, seed: (category, description))
        }
    }

    /// Cuenta de buddies cerca, para el composer de la Home.
    private var scrollContent: some View {
        // Sin ScrollViewReader: el Home ya no se desplaza, así que no hay a
        // dónde llevar el scroll.
        Group {
            scrollBody
                .background(Color.canvas)
                // Keyboard pre-warmer lives in BuddyChatView — InicioView has no knowledge
                // of the keyboard. See KeyboardPrewarmer in ContactarBuddyView.swift.
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: APIJourney.self) { journey in
                    TripDetailGate(journey: journey, match: activeMatch, unreadCount: 0)
                        .environmentObject(routeStore)
                }
                .navigationDestination(for: APIPlaceCard.self) { place in
                    PlaceGuideMapSheet(place: place)
                }
                .navigationDestination(for: DestinationMapRoute.self) { route in
                    PlaceGuideMapSheet(destinationId: route.destinationId, name: route.name)
                }
                .navigationDestination(for: String.self) { route in
                    stringDestination(route: route)
                }
                .task {
                    guard !hasLoaded else { return }
                    hasLoaded = true
                    await loadData()
                }
                .onAppear {
                    if hasLoaded {
                        if skipNextRefresh { skipNextRefresh = false; return }
                        // En TabView los tabs ocultos reciben onAppear en re-renders
                        // (p. ej. cada evento de ChatStore mientras chateas). Sin este
                        // gate, refreshTripState escribe estado → re-render → onAppear
                        // → refreshTripState: loop infinito contra el backend.
                        guard router.selectedTab == .inicio else { return }
                        // Cada fix del GPS re-renderiza el Home y TabView vuelve a
                        // mandar onAppear: con 10 s, quieto y con el ruido del GPS,
                        // cada fix disparaba journeys → matches → contexto →
                        // solicitudes → recent-help. 60 s basta para enterarse al
                        // volver de otra pantalla; los cambios reales llegan por
                        // SSE (travelerMatchSignature) y notificaciones.
                        let age = Date().timeIntervalSince(lastRefreshTripStateAt ?? .distantPast)
                        guard age >= 60 else { return }
                        dlog("🔄 [refreshTripState] onAppear (última hace \(Int(age))s)")
                        Task { await refreshTripState() }
                    }
                }
                .onChange(of: placeDeepLink.pending != nil) { _, hasPending in
                    if hasPending, let journey = activeJourney ?? pendingJourney {
                        navPath = NavigationPath()
                        navPath.append(journey)
                    }
                }
                .onChange(of: navPath.count) { old, new in
                    // Al volver de navegación interna solo refrescamos estado del trip
                    // (journeys + match) — loadData completo no es necesario y causa
                    // que el scroll vuelva al top al reasignar publicJourneys.
                    if new == 0 && old > 0 { Task { await refreshTripState() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
                    Task { await loadData(force: true, reason: "publicado") }
                    showPublishSuccessToast = true
                    UIAccessibility.post(notification: .announcement, argument: "Historia publicada")
                }
                // Sin toast: acá no se publicó nada, solo cambió el contenido
                // de un lugar que el carrusel ya estaba mostrando.
                .onReceive(NotificationCenter.default.publisher(for: .placePhotosChanged)) { _ in
                    Task { await loadData(reason: "fotos") }
                }
                .onReceive(NotificationCenter.default.publisher(for: .helpCompleted)) { _ in
                    Task { await loadRecentHelp(force: true); await refreshTripState() }
                }
                .onChange(of: travelerMatchSignature) { _, _ in
                    Task { await refreshTripState() }
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, hasLoaded else { return }
                    // Throttle: don't refresh more than once per 30 seconds
                    let timeSinceLastRefresh = Date().timeIntervalSince(lastRefreshTripStateAt ?? Date.distantPast)
                    guard timeSinceLastRefresh >= 30 else { return }
                    Task { await refreshTripState() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .journeyCancelled)) { _ in
                    skipNextRefresh = true
                    activeJourney  = nil
                    pendingJourney = nil
                    navPath = NavigationPath()
                    Task { await loadData(force: true, reason: "cancelado") }
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Image("BuddyLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 30)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .tabReselected)) { note in
                    guard note.object as? Int == AppTab.inicio.rawValue else { return }
                    if !navPath.isEmpty { navPath = NavigationPath() }
                    reshuffleToken += 1
                    Task { await loadData(force: true, reason: "tab") }
                }
        }
    }

    /// El Home cabe entero en una pantalla y no se desplaza: sin scroll no hay
    /// rebote ni "hay más abajo" que no existe. Lo que se ve —lugares cerca y
    /// el botón de consultar— es todo lo que hay.
    private var scrollBody: some View {
        // La pantalla no se desplaza: el carrusel toma el espacio que sobra
        // después del título, la disponibilidad y "Consultar a buddies", y su
        // tarjeta se calcula de ese alto MEDIDO. Estimar el alto del resto
        // dejaba el botón debajo de la tab bar en algunos móviles.
        homeStack
            .environment(\.exploreFitsScreen, true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { alto in
                dlog("📐 [layout] Home disponible=\(Int(alto))")
            }
    }

    private var homeStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 0)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in }


                if loadDataFailed && !isLoadingData {
                    Button {
                        Task { await loadData(force: true, reason: "reintentar") }
                    } label: {
                        Label("No pudimos cargar. Reintentar", systemImage: "arrow.clockwise")
                            .font(BT.footnote)
                            .foregroundStyle(Color.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.sm)
                }

                Group {
                    if isLoadingData {
                        // Real components, statically redacted — not a hand-built fake
                        // screen. (Tried .shimmer() on top of the white card surfaces —
                        // its .plusLighter blend mode blew the whole thing out to solid
                        // white. Static redacted reads clean, App Store-style, no risk.)
                        // Same VStack shape as noTripComposer (the state this
                        // almost always resolves to), so when data arrives there's no
                        // layout jump: placeholder bars just turn into real text/icons
                        // in place.
                        // Sin la barra suelta que había arriba: imitaba una fila
                        // de encabezado que en el estado resuelto no existe —el
                        // título vive DENTRO del picker— así que al llegar los
                        // datos desaparecía y todo subía 18pt. El picker ya trae
                        // su propio esqueleto con la silueta del carrusel.
                        CategoryPickerView(isSkeleton: true, hidesCategoryGrid: true) { _, _ in }
                            .padding(.horizontal, -Spacing.edge)
                            .skeletonPulse()
                    } else {
                        homeComposer
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, isLoadingData || homeComposerHasHeaderRow ? Spacing.md : 0)
                // El composer ocupa el alto libre: dentro, el carrusel es lo
                // único elástico, así que el sobrante va a la foto y el botón
                // se queda donde debe.
                .frame(maxHeight: .infinity)
                // Loader visible mientras se procesa la intención (flujo pioneer:
                // crear trip + solicitud) — sin esto la pantalla parece congelada.
                .overlay {
                    if isFindingBuddy {
                        HStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(Color.brand)
                            Text("Registrando tu solicitud…")
                                .font(BT.footnoteBold)
                                .foregroundStyle(Color.ink)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isFindingBuddy)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Abre la guía del destino resuelto por GPS. Sin trip no hay un APIJourney
    /// que empujar, y el destino tampoco es un spot: necesita su propia ruta.
    private func openResolvedDestinationMap() {
        guard let dest = resolvedLocation else { return }
        navPath.append(DestinationMapRoute(destinationId: dest.destinationId, name: dest.destinationName))
    }

    /// Handler compartido del CategoryPickerView — igual para ambos contextos.
    private func handleComposerRequest(category: String, description: String?) {
        requireIdentity {
            guard !isFindingBuddy else { return }
            isFindingBuddy = true
            Task {
                defer { isFindingBuddy = false }
                await submitHelpFromHome(category: category, description: description)
            }
        }
    }

    /// Composer único de Home. El selector de contexto decide CUÁL de los dos
    /// layouts de abajo se muestra — ya no es "hay trip" lo que manda, es la
    /// elección explícita del usuario (effectiveHomeContext). Sin selección
    /// posible (Case 4: sin GPS y sin trip) se mantiene el flujo de permisos/
    /// registro existente, sin cambios.
    /// Un match activo del viajero es SU buddy, exista o no un trip para él.
    private var activeBuddyFirstName: String? {
        activeMatch.flatMap { m in
            ["accepted", "active", "pending"].contains(m.status)
                ? m.buddy?.fullName?.components(separatedBy: " ").first?.capitalized
                : nil
        }
    }

    private var activeBuddyAvatarUrl: String? {
        activeMatch.flatMap { m in
            ["accepted", "active", "pending"].contains(m.status) ? m.buddy?.avatarUrl : nil
        }
    }

    /// El match visible en el CTA — el mismo criterio que activeBuddyFirstName,
    /// resuelto una vez para no repetir la lista de estados en cada helper.
    private var ctaMatch: APIMatch? {
        activeMatch.flatMap { ["accepted", "active", "pending"].contains($0.status) ? $0 : nil }
    }

    private var ctaConnection: ChatStore.ConnectionItem? {
        ctaMatch.flatMap { m in chatStore.connections.first { $0.id == m.id } }
    }

    private var activeBuddyLastMessage: String? {
        guard let conn = ctaConnection, conn.lastMessage != nil else { return nil }
        return conn.isLastFromMe ? "Tú: \(conn.lastText)" : conn.lastText
    }

    /// Pendiente de respuesta — misma regla que el badge del tab Conexiones.
    private var activeBuddyHasUnread: Bool { ctaConnection?.pendingReply == true }

    /// El chat abre SIEMPRE, directo: ConnectionItem solo necesita el match, así
    /// que no hace falta esperar a que chatStore haya sincronizado este hilo.
    private func openAssignedBuddyChat() {
        guard let match = ctaMatch else { return }
        homeChatTarget = ctaConnection
            ?? ChatStore.ConnectionItem(match: match, lastMessage: nil, unreadCount: 0)
    }

    @ViewBuilder private var homeComposer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let activeJrn = effectiveTripJourney {
                let activeDest = activeJrn.destination?.name ?? activeJrn.place?.name
                CategoryPickerView(
                    buddyCount: homeBuddyCount,
                    destinationName: activeDest,
                    onDestinationTap: { navPath.append(activeJrn) },
                    activeBuddyName: activeBuddyFirstName,
                    activeBuddyAvatarUrl: activeBuddyAvatarUrl,
                    communityContext: homeCommunityContext,
                    placeCards: exploreCards,
                    hidesCategoryGrid: true,
                    activeBuddySubtitle: activeBuddyLastMessage,
                    activeBuddyHasUnread: activeBuddyHasUnread,
                    searchingCategoryKey: openRequest?.category,
                    onOpenBuddyChat: openAssignedBuddyChat,
                    onOpenPlace: { navPath.append($0) },
                    isLoading: isFindingBuddy,
                    onStartConversation: startConversationFromHome,
                    reshuffleToken: reshuffleToken
                ) { cat, desc in handleComposerRequest(category: cat, description: desc) }
                .padding(.horizontal, -Spacing.edge)
                .opacity(isFindingBuddy ? 0.5 : 1)
                .disabled(isFindingBuddy)

                // La card de buddy asignado es del trip ACTIVO con match — si el
                // trip elegido en el selector es otro (ej: Villa Rica, planning,
                // sin match), no aplica acá.
                // "¿Vas a viajar?" solo aplica sin trip — se omite en este contexto.
            } else {
                if effectiveHomeContext == nil {
                    // Case 4: ni GPS ni trip — flujo de permisos/registro existente.
                    locationContext
                }
                CategoryPickerView(
                    buddyCount: homeBuddyCount,
                    destinationName: resolvedLocation?.destinationName ?? locationService.currentCity,
                    onDestinationTap: resolvedLocation == nil ? nil : openResolvedDestinationMap,
                    activeBuddyName: activeBuddyFirstName,
                    activeBuddyAvatarUrl: activeBuddyAvatarUrl,
                    communityContext: homeCommunityContext,
                    placeCards: exploreCards,
                    pioneerRequiresCategory: homeCommunityContext?.totalBuddies == 0,
                    hidesCategoryGrid: true,
                    activeBuddySubtitle: activeBuddyLastMessage,
                    activeBuddyHasUnread: activeBuddyHasUnread,
                    searchingCategoryKey: openRequest?.category,
                    onOpenBuddyChat: openAssignedBuddyChat,
                    onOpenPlace: { navPath.append($0) },
                    isLoading: isFindingBuddy,
                    onStartConversation: startConversationFromHome,
                    reshuffleToken: reshuffleToken
                ) { cat, desc in handleComposerRequest(category: cat, description: desc) }
                .padding(.horizontal, -Spacing.edge)
                .opacity(isFindingBuddy ? 0.5 : 1)
                .disabled(isFindingBuddy)

                // "¿Vas a viajar?" oculto por ahora en todos los casos.
            }
        }
    }

    @ViewBuilder private func stringDestination(route: String) -> some View {
        if route == "register" {
            RegisterTripView { journey in
                dlog("🧳 [onJourneyCreated] id=\(journey.id.prefix(8)) dest=\(journey.destination?.name ?? journey.destinationId ?? "?") liveJourneys.before=\(liveJourneys.count)")
                navPath = NavigationPath()
                if homeHelpSeed != nil {
                    dlog("🧳 [onJourneyCreated] path=contactSheet — seteando activeJourney directo")
                    confirmedHelpSeed = homeHelpSeed
                    homeHelpSeed = nil
                    activeJourney = journey
                    lastContactSheetJourney = journey
                    contactSheetJourney = journey
                } else {
                    dlog("🧳 [onJourneyCreated] path=switchToTrips — liveJourneys sigue en \(liveJourneys.count)")
                    router.switchTo(.trips)
                }
            }
        } else if route == "tripDetail", let journey = activeJourney {
            TripDetailView(
                route: routeStore.route,
                match: activeMatch,
                journey: journey,
                unreadCount: pendingReply ? 1 : 0
            )
            .environmentObject(routeStore)
        }
    }

    // MARK: – Assigned buddy card (paridad con AssignedBuddyCard de Android)



    /// Busca una solicitud propia todavía sin atender en el destino vigente.
    /// Con match ya no aplica: ese mismo pedido dejó de estar en búsqueda.
    private func refreshOpenRequest(hasMatch: Bool) async {
        guard Session.hasSession, !hasMatch else {
            await MainActor.run { openRequest = nil }
            return
        }
        let destId = effectiveTripJourney.flatMap { $0.destination?.id ?? $0.destinationId }
            ?? resolvedLocation?.destinationId
        guard let destId else {
            await MainActor.run { openRequest = nil }
            return
        }
        let myId = Session.travelerId
        let requests = (try? await APIClient.shared.fetchOpenRequests(destinationId: destId)) ?? []
        let mine = requests.first { $0.travelerId == myId && $0.isActive }
        await MainActor.run { openRequest = mine }
        dlog("🏠 [refreshOpenRequest] destId=\(destId.prefix(8)) → \(mine.map { "abierta cat=\($0.category)" } ?? "ninguna")")
    }

    /// Resuelve el GPS contra el backend y actualiza `resolvedLocation`.
    ///
    /// Separado de refreshHomeCommunityContext a propósito: antes la resolución
    /// vivía DENTRO de la rama "sin trip", después de un `return` temprano. Con
    /// un trip vivo nunca se ejecutaba, así que `resolvedLocation` se quedaba en
    /// nil para siempre y el Home no seguía al viajero: estando en Villa Rica
    /// con un trip a Chanchamayo, effectiveHomeContext no podía ver el GPS y
    /// caía a `liveJourneys.first` — Chanchamayo. Resolviendo ANTES de elegir
    /// rama, las reglas de effectiveHomeContext por fin reciben el dato que
    /// necesitan y aplican lo que siempre dijeron: GPS que no coincide con un
    /// trip → Ubicación actual.
    private func refreshResolvedLocation() async {
        guard let loc = locationService.userLocation else { return }

        // Throttle propio, porque refreshHomeCommunityContext se llama desde
        // muchos sitios (loadData, refreshTripState, journeyActivated, el
        // selector…), no solo desde el onChange del GPS. Al subir la
        // resolución fuera de la rama "sin trip" pasó a ejecutarse en todos
        // ellos: en un arranque se vieron cuatro POST /location/resolve con
        // las MISMAS coordenadas. Si no te has movido, la respuesta no puede
        // haber cambiado.
        let movido = lastResolveLocation.map { loc.distance(from: $0) } ?? .greatestFiniteMagnitude
        let edad   = Date().timeIntervalSince(lastResolveAt ?? .distantPast)
        if movido < Self.locationRefreshMeters, edad < 60, resolvedLocation != nil {
            dlog("🏠 [refreshResolvedLocation] sin cambios (\(Int(movido))m, \(Int(edad))s) — reutilizo \(resolvedLocation?.destinationName ?? "nil")")
            return
        }
        await MainActor.run {
            lastResolveLocation = loc
            lastResolveAt = Date()
        }

        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude

        do {
            let resolution = try await APIClient.shared.resolveLocation(lat: lat, lng: lng)
            await MainActor.run { applyResolvedLocation(resolution) }
        } catch is URLError {
            // Red caída ≠ "no estás en ningún sitio". Conservar la última
            // resolución: borrarla mandaba el Home a modo pioneer por un
            // túnel o un ascensor, y volvía con otro contenido al salir.
            print("🏠 [refreshResolvedLocation] ⚠️ red caída — conservo \(resolvedLocation?.destinationName ?? "nil")")
        } catch {
            // 204 sin match (el body vacío no decodifica) → fuera de cobertura.
            await MainActor.run { applyResolvedLocation(nil) }
        }
    }

    /// Aplica la resolución y avisa si el destino CAMBIÓ. El aviso es la mitad
    /// de la función: cuando el contenido se reemplaza sin decir por qué, se
    /// lee como un glitch — no como el Home siguiéndote.
    @MainActor
    private func applyResolvedLocation(_ resolution: APILocationResolution?) {
        let previousId   = resolvedLocation?.destinationId
        let previousName = resolvedLocation?.destinationName
        resolvedLocation = resolution

        guard let resolution else {
            if previousId != nil { print("🏠 [location] \(previousName ?? "?") → fuera de cobertura") }
            return
        }
        // Solo en el CAMBIO, no en la primera resolución: al abrir la app
        // "Ahora en Villa Rica" no es una novedad, es el estado inicial.
        guard let previousId, previousId != resolution.destinationId else { return }

        dlog("🏠 [location] \(previousName ?? "?") → \(resolution.destinationName)")
        locationChangeMessage = "Ahora en \(resolution.destinationName)"
        showLocationChangeToast = true
    }

    /// Recarga SOLO el carrusel de spots para la ubicación actual.
    ///
    /// loadData() completo trae journeys, matches, feed y destinos — demasiado
    /// para repetirlo cada vez que el viajero avanza unos cientos de metros.
    /// Los spots son lo único que depende de las coordenadas exactas.
    /// Reordena por cercanía los spots que ya están en pantalla, sin red.
    ///
    /// El backend ya los manda ordenados, pero para la posición que tenía el
    /// viajero cuando se pidieron. Caminando, ese orden envejece enseguida —
    /// los dos primeros están a 14 y 54 m. Con las coordenadas ya en el modelo,
    /// mantenerlo al día es una comparación local por fix.
    ///
    /// Sin animación cuando el orden no cambia: reasignar el array igualmente
    /// haría trabajo de diff a SwiftUI en cada tick del GPS.
    @MainActor
    private func resortSpots(from loc: CLLocation) {
        spotsStore.reorder(from: loc)
    }

    private func refreshSpotsForLocation() async {
        await SpotsStore.shared.refresh(lat: feedLat, lng: feedLng, reason: "gps")
    }

    private func refreshHomeCommunityContext() async {
        // Resolver el GPS SIEMPRE y ANTES de elegir rama: effectiveTripJourney
        // se calcula a partir de effectiveHomeContext, que necesita saber si
        // hay ubicación resuelta para decidir. Consultarlo antes de resolver
        // era preguntar con la respuesta a medias.
        await refreshResolvedLocation()

        // Si el contexto elegido es un trip, cargar el contexto de SU destino o
        // lugar (no necesariamente liveJourneys.first — puede ser cualquiera de
        // los trips vivos). Si el viajero eligió "Ubicación actual" (aunque haya
        // trip(s) vivo(s)), cae al branch de GPS de abajo — el contexto mostrado
        // siempre coincide con la ubicación que realmente se usará para el
        // Help Request.
        if let j = effectiveTripJourney {
            dlog("🏠 [refreshHomeCommunityContext] active trip — loading context")
            if let destId = j.destination?.id ?? j.destinationId,
               let ctx = try? await APIClient.shared.fetchPlaceContext(id: destId, source: "destination") {
                await MainActor.run { homeCommunityContext = ctx; homeBuddyCount = ctx.buddies }
                dlog("🏠 [refreshHomeCommunityContext] ✅ loaded from destination: buddies=\(ctx.buddies)")
            } else if let placeId = j.placeId,
                      let ctx = try? await APIClient.shared.fetchPlaceContext(id: placeId, source: "place") {
                await MainActor.run { homeCommunityContext = ctx; homeBuddyCount = ctx.buddies }
                dlog("🏠 [refreshHomeCommunityContext] ✅ loaded from place: buddies=\(ctx.buddies)")
            } else {
                await MainActor.run {
                    homeCommunityContext = APIPlaceContext(buddies: 0, totalBuddies: 0, stories: 0, status: "pioneer")
                    homeBuddyCount = 0
                }
                print("🏠 [refreshHomeCommunityContext] ❌ no context found — pioneer mode")
            }
            return
        }
        // Sin trip elegido — manda el destino que resolvió el backend arriba
        // (polígono → radio). Nunca la lista de 5 destacados: elegía el vecino
        // equivocado (ej: "Estás en La Merced" estando en Villa Rica).
        if let resolution = resolvedLocation {
            dlog("🏠 [refreshHomeCommunityContext] sin trip → \(resolution.destinationName) (\(resolution.matchedBy), \(resolution.distanceMeters)m)")
            // Con el destino resuelto ya se puede cargar "Comunidad viva"
            // aunque no exista trip (loadRecentHelp usa resolvedLocation).
            await loadRecentHelp()
    
            // Cargar contexto de la comunidad de este destino
            // Con el GPS del viajero: el conteo es de buddies que CUBREN este
            // punto (migración 018), no solo de los que tienen el destino en su
            // lista — por eso Breña decía 0 con buddies de Lima cubriendo la zona.
            if let ctx = try? await APIClient.shared.fetchPlaceContext(id: resolution.destinationId, source: "destination",
                                                                      lat: feedLat, lng: feedLng) {
                await MainActor.run { homeCommunityContext = ctx; homeBuddyCount = ctx.buddies }
                dlog("🏠 [refreshHomeCommunityContext] ✅ loaded context: buddies=\(ctx.buddies)")
                return
            }

            // Sin contexto: pioneer mode
            await MainActor.run {
                homeCommunityContext = APIPlaceContext(buddies: 0, totalBuddies: 0, stories: 0, status: "pioneer")
                homeBuddyCount = 0
            }
            dlog("🏠 [refreshHomeCommunityContext] → pioneer mode (0 buddies)")
        } else if locationService.userLocation != nil {
            // Hay GPS pero fuera de cobertura de todo destino conocido.
            await MainActor.run {
                homeCommunityContext = APIPlaceContext(buddies: 0, totalBuddies: 0, stories: 0, status: "pioneer")
                homeBuddyCount = 0
            }
            dlog("🏠 [refreshHomeCommunityContext] sin match de ubicación → pioneer mode")
        } else {
            dlog("🏠 [refreshHomeCommunityContext] no location — skipping")
        }
    }

    /// Card de un trip de Home — el match/badge dependen de si está activo.
    /// La actividad de la comunidad es la del DESTINO de este trip (cada lugar
    /// tiene su propia comunidad), no la del destino activo.
    @ViewBuilder
    private func tripCard(for journey: APIJourney) -> some View {
        let isActive = journey.status == "active"
        let destId = journey.destination?.id ?? journey.destinationId
        let help = destId.flatMap { recentHelpByDest[$0] } ?? []
        let helperName = help.first?.buddy?.fullName?.components(separatedBy: " ").first?.capitalized
        ActiveTripCard(
            journey: journey,
            match: isActive ? activeMatch : nil,
            pendingReply: pendingReply,
            statusText: isActive ? "EN CURSO" : "PRÓXIMO",
            recentHelperName: helperName,
            recentHelperTimeAgo: help.first.map { timeAgo($0.completedAt) },
            recentHelperAvatars: help.map { $0.buddy?.avatarUrl },
            recentHelperTotal: help.count,
            onContactBuddy: {
                if isActive {
                    print("🔵 [onContactBuddy] active — opening sheet journey=\(journey.id)")
                    lastContactSheetJourney = journey
                    contactSheetJourney = journey
                } else {
                    print("🔵 [onContactBuddy] pending — journey=\(journey.id) pendingJourney_before=\(pendingJourney?.id ?? "nil")")
                    pendingJourney = journey
                    showPendingContactSheet = true
                }
            },
            onOpenDetail: {
                if isActive { navPath.append("tripDetail") } else { navPath.append(journey) }
            }
        )
    }

    /// Revalida solo el estado del trip (activo/pendiente) — barato y frecuente.
    /// Cancela la llamada anterior si llegan múltiples disparos en ráfaga (post-creación de trip).
    private func refreshTripState(line: Int = #line) async {
        // Quién la pidió: al arrancar corre justo al terminar loadData y repite
        // journeys, matches, contexto y recent-help sin causa visible.
        let desdeCarga = Int(Date().timeIntervalSince(lastLoadDataAt ?? .distantPast))
        dlog("🔄 [refreshTripState] pedida — línea \(line) (última carga completa hace \(desdeCarga)s)")
        refreshStateTask?.cancel()
        let t = Task<Void, Never> { await _refreshTripStateBody() }
        refreshStateTask = t
        await t.value
    }

    private func _refreshTripStateBody() async {
        guard !isLoadingData else { print("🔄 [refreshTripState] loadData en vuelo — skip"); return }
        guard Session.hasSession else { print("🔄 [refreshTripState] sin sesión — skip"); return }
        guard !Task.isCancelled else { return }

        // Mark refresh time to throttle scenePhase changes
        await MainActor.run { lastRefreshTripStateAt = Date() }
        guard let journeys = try? await JourneysStore.shared.load(trigger: "inicio:refreshTripState") else {
            print("❌ [refreshTripState] fetchTravelerJourneys falló")
            return
        }
        dlog("🔄 [refreshTripState] \(journeys.count) journey(s): \(journeys.map { "\($0.destination?.name ?? "?"):\($0.status ?? "nil")" })")
        let active   = journeys.first(where: { $0.status == "active" })
        let planning = journeys.first(where: { $0.status == "planning" })

        // Recalcular el match activo — al cerrar un apoyo el match deja de estar
        // en estados activos, así el card vuelve a mostrar el ícono (no la foto).
        // Sin condicionar a `active`: desde el flujo conversacional el match
        // nace ANTES que el trip (el trip se crea al aceptar), así que exigir
        // trip primero dejaba al Home ciego justo en el caso nuevo.
        let matches = (try? await MatchingStore.shared.load(trigger: "inicio:refreshTripState")) ?? []
        let myId = Session.travelerId
        let resolvedMatch = matches.first(where: {
            ["accepted", "active", "pending"].contains($0.status) && $0.travelerId == myId
        })

        await MainActor.run {
            activeJourney  = active
            pendingJourney = planning
            activeMatch    = resolvedMatch
            liveJourneys   = journeys
                .filter { ["active", "planning"].contains($0.status) }
                .sorted { ($0.status == "active" ? 0 : 1) < ($1.status == "active" ? 0 : 1) }
            dlog("🔄 [refreshTripState] ✅ state written — activeJourney=\(active?.id.prefix(8) ?? "nil") liveJourneys=\(liveJourneys.count)")
        }
        // refreshHomeCommunityContext PRIMERO: resuelve resolvedLocation, del que
        // depende effectiveHomeContext — loadRecentHelp necesita ese valor fresco
        // para decidir si mostrar actividad local o caer al pulso global.
        await refreshHomeCommunityContext()
        await refreshOpenRequest(hasMatch: resolvedMatch != nil)
        await loadRecentHelp()
        await loadRecentHelpPerTrip()
        // Ruta en background — activos y planning la necesitan para el mapa
        if let active, !routeStore.isReady {
            let destId = active.destination?.id ?? active.destinationId
            await routeStore.fetchDestinationFromAPI(id: destId)
        } else if active == nil, let planning = journeys.first(where: { $0.status == "planning" }), !routeStore.isReady {
            let destId = planning.destination?.id ?? planning.destinationId
            await routeStore.fetchDestinationFromAPI(id: destId)
        }
    }

    /// Fetch ligero para navegar al detalle rápido tras "Ya llegué"
    private func quickLoadForDetail() async {
        guard Session.hasSession else { return }
        guard let journeys = try? await APIClient.shared.fetchTravelerJourneys() else { return }
        let active = journeys.first(where: { $0.status == "active" })

        // Asegura que routeStore tenga la ruta
        if let active, !routeStore.isReady {
            let destId = active.destination?.id ?? active.destinationId
            await routeStore.fetchDestinationFromAPI(id: destId)
        }

        // Cargar match si hay viaje activo
        if let active {
            let matches = try? await MatchingStore.shared.load(trigger: "inicio:quickLoadForDetail")
            let all = matches ?? []
            let myId2 = Session.travelerId
            let found = all.first(where: { ["accepted", "active", "pending"].contains($0.status) && $0.travelerId == myId2 })
            await MainActor.run {
                activeJourney = active
                activeMatch = found
            }
        }

        // Navegar cuando routeStore esté listo (onChange lo maneja si aún no está)
        if routeStore.isReady, active != nil {
            await MainActor.run {
                guard pendingNavToDetail else { return }
                pendingNavToDetail = false
                router.switchTo(.inicio)
                navPath.append("tripDetail")
            }
        }
    }

    private func activateNextTrip() async {
        guard !isActivatingNextTrip else { return }
        guard let current = activeJourney, let next = pendingJourney else { return }
        isActivatingNextTrip = true
        defer { isActivatingNextTrip = false }
        do {
            // 1. Cancel active buddy match
            if let match = activeMatch {
                _ = try? await APIClient.shared.updateMatchStatus(matchId: match.id, status: "cancelled")
            }
            // 2. Complete current trip
            try await APIClient.shared.updateJourneyStatus(journeyId: current.id, status: "completed")
            // 3. Activate next trip
            try await APIClient.shared.updateJourneyStatus(journeyId: next.id, status: "active")
            // 4. Refresh
            await loadData()
        } catch {
            print("❌ [activateNextTrip] \(error)")
        }
    }

    /// Una carga completa del Home a la vez. Dos disparos seguidos (p. ej. al
    /// volver de una pantalla y una notificación casi a la vez) hacían dos
    /// rondas enteras de journeys, matches, mensajes, ofertas, historias y
    /// spots. Si hay una en vuelo o terminó hace menos de 5 s, se ignora; los
    /// gestos explícitos del usuario (pull to refresh, reintentar, tocar el
    /// tab) pasan `force: true`.
    private func loadData(force: Bool = false, reason: String = "", line: Int = #line) async {
        // Quién la pidió: sin esto no se sabe qué disparó una segunda carga
        // completa (la de las 20:29:13 no tenía causa visible en los logs).
        let origen = reason.isEmpty ? "línea \(line)" : "\(reason), línea \(line)"
        dlog("🏠 [loadData] pedida — \(origen)\(force ? " (force)" : "")")
        let edad = Date().timeIntervalSince(lastLoadDataAt ?? .distantPast)
        if !force, loadDataTask != nil || edad < 5 {
            dlog("🏠 [loadData] \(reason.isEmpty ? "" : "(\(reason)) ")ignorado — \(loadDataTask != nil ? "ya hay una carga en vuelo" : "última hace \(Int(edad))s")")
            return
        }
        // Cancel any in-flight loadData — only the latest matters.
        loadDataTask?.cancel()
        let task = Task<Void, Never> { [self] in await _loadDataBody(force: force) }
        loadDataTask = task
        await task.value
        if loadDataTask == task {
            loadDataTask = nil
            lastLoadDataAt = Date()
        }
    }

    private func _loadDataBody(force: Bool) async {
        guard !Task.isCancelled else { return }
        await MainActor.run { loadDataFailed = false }
        // ── Contenido PÚBLICO: siempre carga, sin importar la sesión ──
        // exploreCards va en paralelo con destinations, ANTES de que
        // isLoadingData pase a false — si se carga después (como antes),
        // el composer alcanza a pintar la grilla de categorías vacía de
        // fotos y recién after eso salta al carrusel, un flash visible.
        // Spots: sin esperar y sin reemplazar. La lista en pantalla sale del
        // cache de SpotsStore, así que no hay que retener isLoadingData por
        // ella; y si esta petición falla, la lista buena se conserva.
        //
        // Con permiso de ubicación pero todavía sin fix, no se pide aquí: el
        // primer fix lo hará con coordenadas. Pedirla ahora sin coordenadas y
        // otra vez un segundo después era la petición duplicada del arranque.
        let authorized = locationService.authorizationStatus == .authorizedWhenInUse ||
                         locationService.authorizationStatus == .authorizedAlways
        if feedLat != nil || !authorized {
            Task { await SpotsStore.shared.refresh(lat: feedLat, lng: feedLng, reason: "loadData") }
        } else {
            dlog("🗂️ [spots] loadData: esperando el primer fix del GPS para pedir con coordenadas")
        }

        let fetchedDests = (try? await APIClient.shared.fetchDestinations()) ?? []
        await MainActor.run {
            destinations = fetchedDests
            ImagePrefetcher.prefetch(destinations.compactMap { $0.coverUrl })
        }

        // Sin ninguna sesión (ni guest ni verified): solo contenido público.
        let tid = Session.travelerId
        dlog("🏠 [loadData] hasSession=\(Session.hasSession) travelerId=\(tid?.prefix(8) ?? "nil") isVerified=\(Session.isVerified)")
        guard Session.hasSession else {
            dlog("🏠 [loadData] sin sesión — solo contenido público")
            await MainActor.run { isLoadingData = false }
            await refreshHomeCommunityContext()
                return
        }
        // ── Contenido PRIVADO: guest y verified cargan sus journeys ──

        do {
            // fetchTravelerJourneys usa el JWT (traveler o Supabase) — válido para ambos.
            let snapshotId = Session.travelerId   // capturar ANTES del await
            dlog("🏠 [loadData] fetching journeys para travelerId=\(snapshotId?.prefix(8) ?? "nil")…")
            let store = JourneysStore.shared
            let journeys: [APIJourney]
            if force {
                journeys = try await store.refresh(trigger: "inicio:loadData")
            } else {
                journeys = try await store.load(trigger: "inicio:loadData")
            }
            guard !Task.isCancelled else { return }
            dlog("🏠 [loadData] \(journeys.count) journey(s) recibidos: \(journeys.map { "\($0.destination?.name ?? "?"):\($0.status ?? "nil")" })")
            // Anti cross-account guard: if identity was hydrated mid-flight (cold launch
            // where validate() forces a refresh after loadData already started with nil),
            // discard the stale response and retry immediately with the correct identity.
            guard Session.travelerId == snapshotId else {
                let newId = Session.travelerId?.prefix(8) ?? "?"
                print("⚠️ [loadData] travelerId cambió (nil → \(newId)) — descarto y reintento con identidad correcta")
                await MainActor.run { isLoadingData = false }
                Task { await loadData() }
                return
            }
            let active   = journeys.first(where: { $0.status == "active" })
            let planning = journeys.first(where: { $0.status == "planning" })
            dlog("🏠 [loadData] active=\(active?.id.prefix(8) ?? "nil") planning=\(planning?.id.prefix(8) ?? "nil")")

            if let active, !routeStore.isReady {
                let destId = active.destination?.id ?? active.destinationId
                await routeStore.fetchDestinationFromAPI(id: destId)
            } else if active == nil, let planning, !routeStore.isReady {
                let destId = planning.destination?.id ?? planning.destinationId
                await routeStore.fetchDestinationFromAPI(id: destId)
            }

            // Calcular nuevo estado antes de escribir al MainActor.
            let newLive = journeys
                .filter { ["active", "planning"].contains($0.status) }
                .sorted { ($0.status == "active" ? 0 : 1) < ($1.status == "active" ? 0 : 1) }
            await MainActor.run {
                // No pisamos activeJourney si el contact sheet está abierto —
                // onDismiss hace el update optimista y refreshTripState confirma.
                if contactSheetJourney == nil {
                    activeJourney = active
                }
                pendingJourney = planning
                liveJourneys   = newLive
                dlog("🏠 [loadData] ✅ state written — activeJourney=\(active?.id.prefix(8) ?? "nil") liveJourneys=\(newLive.count)")
            }

            let shouldFetchMatch = await MainActor.run { activeJourney != nil }
            if shouldFetchMatch {
                let matches = try await MatchingStore.shared.load(trigger: "inicio:loadData")
                guard !Task.isCancelled else { return }
                dlog("🏠 [loadData] \(matches.count) match(es): \(matches.map { "\($0.status ?? "?")" })")
                // Must filter by travelerId: user may simultaneously be a buddy for
                // another traveler, and fetchMatches() returns matches in both roles.
                // Without this guard, the buddy-role match can win the .first() and
                // the home shows the user's own name in the "Hablar con tu buddy" card.
                let myId = Session.travelerId
                let found = matches.first(where: {
                    ["accepted", "active", "pending"].contains($0.status) && $0.travelerId == myId
                })
                await MainActor.run { activeMatch = found }
                await chatStore.load(prefetched: matches)
            }
        } catch {
            // Una carga CANCELADA no es un fallo: pasa cada vez que una carga
            // nueva (arrastrar para refrescar, volver de una pantalla) reemplaza
            // a la que estaba en curso. Marcarla como fallo mostraba "No pudimos
            // cargar" justo cuando la carga nueva ya estaba trayendo los datos.
            let cancelada = error is CancellationError
                || (error as? URLError)?.code == .cancelled
                || Task.isCancelled
            if cancelada {
                dlog("🏠 [loadData] cancelada por una carga más nueva — no es un error")
            } else {
                print("❌ [loadData] ERROR: \(error)")
                await MainActor.run { loadDataFailed = true }
            }
        }
        await MainActor.run { isLoadingData = false }
        let doneJourney = await MainActor.run { activeJourney?.id.prefix(8) ?? "nil" }
        let doneLive = await MainActor.run { liveJourneys.count }
        dlog("🏠 [loadData] done — activeJourney=\(doneJourney) liveJourneys=\(doneLive)")

        // Si viene de "Ya llegué", navegar directo al mapa
        await MainActor.run {
            if pendingNavToDetail, activeJourney != nil, routeStore.isReady {
                pendingNavToDetail = false
                navPath.append("tripDetail")
            }
        }

        // "Historias de viajeros" vive ahora en el tab Trips
        // (TravelerStoriesSection): el Home ya no pide el feed.

        // Buddies cerca para el composer de la Home + resolvedLocation fresco.
        // PRIMERO: loadRecentHelp depende de effectiveHomeContext, que a su vez
        // depende de resolvedLocation — sin este orden, Comunidad Viva podía
        // mostrar la actividad del trip aunque el selector ya mostrara
        // "Ubicación actual" (un ciclo de refresh atrasado).
        await refreshHomeCommunityContext()
        // Sin force: refreshHomeCommunityContext ya la pidió un instante antes
        // cuando no hay trip, y con force salía una segunda recent-help-nearby
        // idéntica en cada carga. El throttle de 30 s deduplica; con trip
        // elegido (que no pasa por ahí) la petición sigue saliendo aquí.
        await loadRecentHelp()
        await loadRecentHelpPerTrip()
        // Comunidad viva es global — no depende de trip ni de GPS resuelto,
        // así que se carga siempre acá, sin importar en qué rama cayó
        // refreshHomeCommunityContext arriba.
    }

    private var feedLat: Double? { locationService.userLocation?.coordinate.latitude }
    private var feedLng: Double? { locationService.userLocation?.coordinate.longitude }


    private func activatePendingJourney(_ journey: APIJourney) async {
        try? await APIClient.shared.updateJourneyStatus(journeyId: journey.id, status: "active")
        await MainActor.run {
            pendingJourney = nil
            activeJourney = journey
            NotificationCenter.default.post(name: .journeyActivated, object: nil)
        }
        await loadData()
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_PE")
        f.dateFormat = "EEEE · d 'de' MMMM"
        return f.string(from: Date()).uppercased()
    }

    // MARK: Comunidad viva — ayudas recién terminadas en tu destino
    /// - Parameter force: ignora el throttle (para pull-to-refresh / eventos reales)
    private func loadRecentHelp(force: Bool = false) async {
        // Regla de Comunidad viva: la actividad local SOLO aplica cuando el
        // contexto EFECTIVO es un trip — y del TRIP ELEGIDO, no necesariamente
        // activeJourney/pendingJourney (con 2+ trips vivos puede ser cualquiera).
        // Con "Ubicación actual" (el default cuando GPS y trip no coinciden —
        // ver effectiveHomeContext), mostrar la actividad de un trip que ni
        // siquiera es el que se está usando ahora mismo confunde: recentHelp
        // queda vacío y la sección cae al pulso global (loadCommunityPulseIfNeeded).
        // La ubicación manda: con GPS, las ayudas de CERCA del viajero, sean del
        // destino que sean. Sin GPS, el destino del trip como antes.
        let geoKey: String? = feedLat.flatMap { la in feedLng.map { String(format: "geo:%.2f,%.2f", la, $0) } }
        guard let destId = geoKey ?? (effectiveTripJourney.flatMap { $0.destination?.id ?? $0.destinationId }) else {
            recentHelp = []; recentHelpDestId = nil; return
        }

        // Anti re-entrada: una sola petición en vuelo a la vez
        if isLoadingRecentHelp { return }

        // Throttle: no refetchar el mismo destino en < 30 s (salvo force).
        // Esto corta el loop de llamadas idénticas disparadas por re-renders.
        if !force,
           recentHelpDestId == destId,
           let at = recentHelpLoadedAt,
           Date().timeIntervalSince(at) < 30 {
            return
        }

        isLoadingRecentHelp = true
        defer { isLoadingRecentHelp = false }
        do {
            let result: [APIRecentHelp]
            if geoKey != nil, let la = feedLat, let lo = feedLng {
                result = try await APIClient.shared.fetchRecentHelpNearby(lat: la, lng: lo)
            } else {
                result = try await APIClient.shared.fetchRecentHelp(destinationId: destId)
            }
            // Solo actualiza si el destino sigue siendo el mismo (anti carrera con
            // cambios de trip) y conserva lo último conocido si llega vacío por un
            // blip — la prueba social no debe parpadear al refrescar.
            if !result.isEmpty || recentHelpDestId != destId {
                recentHelp = result
            }
            recentHelpDestId = destId
            recentHelpLoadedAt = Date()
        } catch {
            // Error transitorio (p. ej. al hacer pull-to-refresh): preserva la
            // info actual en vez de borrarla.
        }
    }

    /// Carga la actividad de comunidad de CADA destino vivo (uno por trip del
    /// carrusel), en paralelo. Así cada card muestra su propia prueba social.
    private func loadRecentHelpPerTrip() async {
        let destIds = Set(liveJourneys.compactMap { $0.destination?.id ?? $0.destinationId })
        await withTaskGroup(of: (String, [APIRecentHelp]).self) { group in
            for id in destIds {
                group.addTask {
                    let r = (try? await APIClient.shared.fetchRecentHelp(destinationId: id)) ?? []
                    return (id, r)
                }
            }
            var collected: [String: [APIRecentHelp]] = [:]
            for await (id, r) in group { collected[id] = r }
            await MainActor.run {
                // Conserva lo previo si algo llega vacío por un blip (no parpadear)
                for (id, r) in collected where !r.isEmpty || recentHelpByDest[id] == nil {
                    recentHelpByDest[id] = r
                }
            }
        }
    }

    // MARK: – Comunidad viva (prueba social encima de HISTORIAS DE VIAJEROS)
    // Con actividad local: "Keyla ayudó a un viajero · hace 2h".
    // Sin ella, el pulso global de la red: "Un viajero está en Villa Rica",
    // "Villa Rica · un buddy ayudó a un viajero · hace 2h",
    // "Villa Rica · 3 buddies listos para ayudar". Máx. 10 filas.
    /// Lista vertical de 3 filas, no un scroller horizontal. Razones, en orden
    /// de peso:
    ///
    /// 1. Desplazarse en horizontal es un gesto de EXPLORACIÓN — promete ítems
    ///    que se recorren y se eligen. Estas filas no son tocables ni llevan a
    ///    ningún lado: prometía un destino inexistente. Apilar en vertical es
    ///    gesto de LECTURA, que es lo que corresponde a una señal ambiente.
    /// 2. Con el carrusel de lugares justo encima había dos zonas de scroll
    ///    horizontal contiguas; un arrastre cerca del límite no dejaba claro
    ///    cuál se movía.
    /// 3. A 150pt por ítem entraban 2,4 filas en pantalla gastando ~100pt de
    ///    alto. Tres filas apiladas ocupan ~96pt y entregan tres mensajes
    ///    completos.
    ///
    /// Tres y no diez porque esto es una SEÑAL, y las señales saturan: al
    /// tercer evento el usuario ya concluyó "hay gente ayudando". Las siete
    /// restantes solo agregan carga y convierten la sección en un feed.
    private var communityLiveSection: some View {
        // 16 entre el header y las filas, 10 entre filas: con ambos a 12 las
        // distancias eran iguales y el header se leía como un cuarto ítem de la
        // lista. Separar la estructura del contenido agrupa las filas entre sí.
        VStack(alignment: .leading, spacing: 16) {
            // Mismo tratamiento que "HISTORIAS DE VIAJEROS": son secciones
            // hermanas y deben pesar igual. El 75% que tenía antes venía de
            // cuando el punto verde acompañaba al título — sin el punto, la
            // línea quedaba atenuada y corta, y se leía como una nota al pie.
            Text("COMUNIDAD VIVA")
                .font(BT.eyebrow).tracking(1.5)
                .foregroundStyle(Color.ink)

            VStack(spacing: 10) {
                ForEach(communityPulse.filter { $0.type == "helped" }.prefix(3)) { item in
                    communityRow(item)
                }
            }
        }
        .padding(.horizontal, Spacing.edge)
        .sheet(item: $pulseProfileTarget) { target in
            TravelerProfileView(travelerId: target.id,
                                previewName: target.name,
                                previewAvatarUrl: target.avatarUrl)
        }
    }

    /// Dos líneas: la acción arriba, el contexto abajo. Cada fila responde las
    /// tres preguntas sin una palabra de más — quién (nombre), en qué
    /// (categoría) y dónde/cuándo (línea 2).
    ///
    /// Avatar 24pt (era 56, luego 28). Se queda porque Buddy vende personas
    /// reales y una cara comunica eso en 100ms — ningún texto lo hace igual de
    /// rápido, aunque a este tamaño no se distingan los rasgos. Solo baja lo
    /// suficiente para no encabezar la fila.
    @ViewBuilder
    private func communityRow(_ item: APIPulseItem) -> some View {
        let name = item.buddyName?.components(separatedBy: " ").first?.capitalized ?? "Un buddy"
        // La fila nombra a una persona: tocarla abre su perfil. Solo cuando el
        // pulso trae su id — sin id no hay perfil que abrir y la fila se queda
        // como estaba, una señal que se lee y no se toca.
        let target = item.buddyId.map {
            PulseProfileTarget(id: $0, name: item.buddyName, avatarUrl: item.buddyAvatarUrl)
        }
        // .top y no centrado: el avatar se alinea con la línea 1, que es la que
        // ancla la fila, igual que en Mail y Mensajes.
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.sandLight)
                .frame(width: 24, height: 24)
                .overlay {
                    if let urlStr = item.buddyAvatarUrl, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color.sandLight }
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.sand)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                // El apoyo se queda con la línea entera y a un solo tamaño. Antes
                // compartía renglón con la hora, que le robaba ancho y la obligaba
                // a una línea; y la acción iba un escalón por debajo del nombre,
                // así que lo que la fila viene a contar se leía más chico que
                // quién lo hizo. Medium y no semibold en el nombre: el ojo tiene
                // que encontrar el sujeto rápido, pero la negrita plena es la
                // firma visual de una red social y convertía el hecho en un post.
                (Text(name).font(BT.footnote.weight(.medium)).foregroundStyle(Color.ink)
                 + Text(" \(pulseAction(item))").font(BT.footnote).foregroundStyle(Color.ink))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                // Los dos metadatos comparten renglón en los extremos opuestos.
                // Así la fila cierra tocando ambos bordes —lo que equilibra una
                // fila de Mail o Mensajes— sin que eso le cueste ancho a la
                // frase, y la ciudad deja de encabezar su línea: al repetirse en
                // las tres filas, arrancarlas todas igual las hacía ver plantilla.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pulseTimeAgo(item))
                        .font(BT.caption2)
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(item.city)
                        .font(BT.caption2)
                        .foregroundStyle(Color.inkMuted)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let target else { return }
            Haptic.light()
            pulseProfileTarget = target
        }
    }

    /// Verbo + complemento corto, SIEMPRE la misma forma. El paralelismo importa
    /// más que la precisión: tres filas con la misma estructura gramatical se
    /// procesan como un conjunto de un vistazo, mientras que tres formas
    /// distintas obligan a re-parsear cada línea.
    ///
    /// Además cortas: "resolvió una consulta sobre transporte" era lenguaje de
    /// mesa de ayuda —sonaba a ticket cerrado, no a alguien ayudando— y con
    /// lineLimit(1) se truncaba justo la acción, que es lo que carga el mensaje,
    /// en cuanto el usuario subía el Dynamic Type.
    ///
    /// `general` y los casos sin categoría caen en formas genéricas: nunca se
    /// inventa un detalle que el dato no tiene.
    private func pulseAction(_ item: APIPulseItem) -> String {
        switch item.category {
        case "transport":         return "ayudó con transporte"
        case "food", "food_recs": return "recomendó dónde comer"
        case "accommodation":     return "ayudó con alojamiento"
        case "activities":        return "recomendó qué hacer"
        case "shopping":          return "ayudó con compras"
        case "translation":       return "tradujo para un viajero"
        case "emergency":         return "asistió una urgencia"
        case "recommendations":   return "dio recomendaciones"
        case "airport_pickup":    return "recibió en el aeropuerto"
        case "city_tour":         return "acompañó por la ciudad"
        default:                  return "ayudó a un viajero"
        }
    }

    /// Con "hace" porque acá va inline tras la ciudad, no en una columna de
    /// timestamps donde el prefijo sobraría. "ayer" en vez de "hace 1 d".
    private func pulseTimeAgo(_ item: APIPulseItem) -> String {
        guard let d = item.at else { return "hace poco" }
        let s = max(0, Date().timeIntervalSince(d))
        if s < 90     { return "hace un momento" }
        if s < 3600   { return "hace \(Int(s / 60)) min" }
        if s < 86400  { return "hace \(Int(s / 3600)) h" }
        if s < 172800 { return "ayer" }
        return "hace \(Int(s / 86400)) d"
    }

    /// Comunidad viva ahora siempre muestra el pulso global (últimas ayudas
    /// en cualquier lugar), sin restringir al destino activo del usuario.
    private func loadCommunityPulseIfNeeded() async {
        // El pulso global cambia lento — no refetchar en < 60 s.
        if let at = communityPulseLoadedAt, Date().timeIntervalSince(at) < 60, !communityPulse.isEmpty {
            dlog("🌐 [loadCommunityPulseIfNeeded] throttled — usando cache de \(communityPulse.count) item(s)")
            return
        }
        do {
            let pulse = try await APIClient.shared.fetchCommunityPulse()
            dlog("🌐 [loadCommunityPulseIfNeeded] ✅ \(pulse.count) item(s): \(pulse.map { "\($0.type)@\($0.city)" })")
            await MainActor.run { communityPulse = pulse; communityPulseLoadedAt = Date() }
        } catch {
            print("❌ [loadCommunityPulseIfNeeded] ERROR: \(error)")
        }
    }

    private func timeAgo(_ date: Date?) -> String {
        guard let d = date else { return "recién" }
        let s = max(0, Date().timeIntervalSince(d))
        if s < 90    { return "hace un momento" }
        if s < 3600  { return "hace \(Int(s / 60)) min" }
        if s < 86400 { return "hace \(Int(s / 3600)) h" }
        return "hace \(Int(s / 86400)) d"
    }
}

// MARK: – TRIP DETAIL GATE
// El mapa necesita la ruta cargada; esta puerta la obtiene al entrar
// (única parte del flujo que depende de la ubicación).

struct TripDetailGate: View {
    let journey: APIJourney
    var match: APIMatch? = nil
    var unreadCount: Int = 0
    @EnvironmentObject var routeStore: RouteStore
    @State private var mapState: MapLoadState = .loading

    var body: some View {
        Group {
            switch mapState {
            case .loading:
                ZStack {
                    Color.canvas.ignoresSafeArea()
                    ProgressView().tint(Color.inkMuted)
                }

            case .guideAvailable:
                TripDetailView(route: routeStore.route, match: match,
                               journey: journey, unreadCount: unreadCount)
                    .environmentObject(routeStore)

            case .noGuide(let lat, let lng):
                // Sin guía curada pero tenemos coords: usar TripDetailView con places:[]
                // para mostrar el mapa centrado + el estado "Sin explorar aún" del sheet.
                let emptyRoute = Route(
                    id: UUID(),
                    title: journey.destination?.name ?? journey.place?.name ?? "Tu destino",
                    subtitle: journey.destination?.city ?? "",
                    city: journey.destination?.city ?? "",
                    places: [],
                    centerLat: lat,
                    centerLng: lng
                )
                TripDetailView(route: emptyRoute, match: match,
                               journey: journey, unreadCount: unreadCount)
                    .environmentObject(routeStore)

            case .noData:
                NoGuideMapView(
                    name: journey.destination?.name ?? journey.place?.name ?? "Tu destino",
                    lat: nil, lng: nil
                )

            case .error:
                VStack(spacing: Spacing.md) {
                    Image(systemName: "map")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.inkMuted)
                    Text("No pudimos cargar la ruta")
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                    Button {
                        mapState = .loading
                        Task { mapState = await routeStore.ensureLoaded(for: journey) }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
            }
        }
        .task {
            let state = await routeStore.ensureLoaded(for: journey)
            dlog("🗺️ [TripDetailGate] journey=\(journey.id.prefix(8)) dest=\(journey.destination?.name ?? "nil") placeId=\(journey.placeId ?? "nil") → mapState=\(state)")
            mapState = state
        }
    }
}

// Vista para viajes GPS sin guía curada: mapa centrado o mensaje informativo.
// Vista para viajes GPS sin guía curada: mapa real con pin, o mensaje si no hay coords.
private struct NoGuideMapView: View {
    let name: String
    let lat: Double?
    let lng: Double?

    var body: some View {
        if let lat, let lng {
            MapPinView(name: name, lat: lat, lng: lng)
        } else {
            VStack(spacing: Spacing.md) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.brand)
                Text(name)
                    .font(BT.title3)
                    .foregroundStyle(Color.ink)
                Text("Aún no tenemos una guía para este destino.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
        }
    }
}

import MapKit

private struct MapPinView: View {
    let name: String
    let lat: Double
    let lng: Double

    @State private var region: MKCoordinateRegion

    /// span por defecto (0.05) = nivel destino, usado por los llamados existentes.
    /// El mapa de un spot concreto pasa uno mucho más chico para hacer zoom ahí.
    init(name: String, lat: Double, lng: Double, span: Double = 0.05) {
        self.name = name
        self.lat  = lat
        self.lng  = lng
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        ))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(coordinateRegion: $region, annotationItems: [MapPin(lat: lat, lng: lng, name: name)]) { pin in
                MapMarker(coordinate: pin.coordinate, tint: Color.brand)
            }
            .ignoresSafeArea(edges: .top)

            // Chip con el nombre del destino sobre el mapa
            HStack(spacing: Spacing.xs) {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(Color.brand)
                Text(name)
                    .font(BT.footnoteBold)
                    .foregroundStyle(Color.ink)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, Spacing.xl)
        }
    }
}

private struct MapPin: Identifiable {
    let id = UUID()
    let lat: Double
    let lng: Double
    let name: String
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

// MARK: – ACTIVE VISIT CARD
// Calm teal gradient. Editorial typography. No gaming badges.

struct ActiveVisitCard: View {
    let route: Route
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(LinearGradient(
                    colors: [Color.tealDeep, Color.teal],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(height: 210)

            VStack(alignment: .leading, spacing: 0) {
                // City eyebrow
                Text(route.city.uppercased())
                    .font(BT.eyebrow)
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, Spacing.md)

                // Hero title
                Text(route.title)
                    .font(BT.displayLarge)
                    .foregroundStyle(.white)
                Text(route.subtitle)
                    .font(BT.displayLarge)
                    .foregroundStyle(.white.opacity(0.8))

                // Progress bar
                HStack(spacing: Spacing.sm) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.18))
                                .frame(height: 2)
                            Capsule()
                                .fill(.white)
                                .frame(
                                    width: appeared ? g.size.width * route.progress : 0,
                                    height: 2
                                )
                                .animation(.easeOut(duration: 0.9).delay(0.3), value: appeared)
                        }
                    }
                    .frame(height: 2)

                    Text("\(route.collectedCount) de \(route.places.count)")
                        .font(BT.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                        .monospacedDigit()
                }
                .padding(.top, Spacing.md)
            }
            .padding(Spacing.md)
        }
        .cardShadow()
        .onAppear { appeared = true }
    }
}

// MARK: – REGISTER CTA CARD

// MARK: – FIND A BUDDY PRIMARY CTA
// Tarjeta principal de la home: pedir ayuda en un toque. El Trip se crea o
// reusa automáticamente — el usuario nunca ve una pantalla de "crear trip".

struct FindBuddyPrimaryCTA: View {
    let destinationName: String?     // ciudad detectada por GPS (si la hay)
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("¿Necesitas ayuda?")
                    .font(BT.title1)
                    .foregroundStyle(Color.ink)
                if let city = destinationName {
                    (Text("Un buddy local te ayuda en minutos en ")
                        .foregroundStyle(Color.inkMuted)
                    + Text(city)
                        .foregroundStyle(Color.brand)
                        .fontWeight(.semibold))
                    .font(BT.callout)
                } else {
                    Text("Un buddy local te ayuda en minutos.")
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                }
            }

            Button(action: { Haptic.medium(); onTap() }) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().tint(.white).controlSize(.small)
                    } else {
                        Image(systemName: "person.wave.2.fill")
                        Text("Buscar un buddy")
                    }
                }
                .font(BT.footnoteBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.brand)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }
            .disabled(isLoading)
        }
        .padding(Spacing.lg)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }
}

// Selector explícito de contexto Home: "Ubicación actual" vs "Mi viaje".
/// Una fila seleccionable del dropdown: un trip vivo (journey.id + nombre a mostrar).
// Carries both pieces the home-help sheet needs atomically.
// Using this as the .sheet(item:) driver eliminates the Bool/optional
// desync that caused blank screens on first open.
/// El destino completo como ruta de navegación. APIJourney no sirve —puede no
/// haber trip— y APIPlaceCard tampoco: eso es un spot, no la ciudad.
struct DestinationMapRoute: Hashable {
    let destinationId: String
    let name: String
}

struct HomeHelpItem: Identifiable {
    let id = UUID()
    let destinationId: String
    let seed: (category: String, description: String?)?
    var journey: APIJourney? = nil
    /// El CTA del carrusel abre la conversación directamente (sin categoría
    /// todavía); el resto de entradas siguen cayendo en el selector clásico.
    var startsConversation: Bool = false
}

// Tarjeta SECUNDARIA: planear un viaje es opcional, no compite con pedir ayuda.
// Fila compacta, plana (sin sombra), con acción terciaria.
struct RegisterCTACard: View {
    let destinations: [APIDestination]   // conservado por compatibilidad
    let onTap: () -> Void

    var body: some View {
        Button(action: { Haptic.light(); onTap() }) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle().fill(Color.sandLight).frame(width: 40, height: 40)
                    Image(systemName: "map")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.sand)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("¿Vas a viajar?")
                        .font(BT.footnoteBold)
                        .foregroundStyle(Color.ink)
                    Text("Regístralo y prepara tu llegada para aprovechar al máximo.")
                        .font(BT.caption1)
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.inkMuted.opacity(0.5))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, Spacing.md)
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Radius.lg).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }
}

// MARK: – DESTINATION THUMB CARD
// Photo card matching design reference: rounded rect photo + name below

struct DestinationThumbCard: View {
    let destination: APIDestination

    // Fallback gradient per destination index
    private let gradients: [[Color]] = [
        [Color(hex: "4A2820"), Color(hex: "6E3B2D")],
        [Color(hex: "3D2B1A"), Color(hex: "6B4226")],
        [Color(hex: "4A3D35"), Color(hex: "7A6558")],
        [Color(hex: "5C3E1A"), Color(hex: "8B6428")],
    ]

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack {
                // Background: real photo or gradient fallback
                CachedImage(urlString: destination.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    gradientFallback
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(destination.city)
                .font(BT.caption1)
                .foregroundStyle(Color.inkMuted)
                .lineLimit(1)
        }
        .frame(width: 80)
    }

    private var gradientFallback: some View {
        let idx = abs(destination.name.hashValue) % gradients.count
        return LinearGradient(
            colors: gradients[idx],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: – PUBLISHED TRIP CARD

// MARK: – TRIP STORY CARD (álbum de viaje)
// La unidad es un trip finalizado, presentado como ÁLBUM. Carrusel estilo IG:
// cada momento se ve COMPLETO (sin recortar) y se desliza ←/→.

/// Identifica al buddy de una fila del pulso para presentar su perfil.
struct PulseProfileTarget: Identifiable {
    let id: String
    let name: String?
    let avatarUrl: String?
}

struct PublishedTripCard: View {
    let journey: APIJourney
    var featured: Bool = false
    var matchesMyDestination: Bool = false
    var nearby: Bool = false

    @State private var showStory = false
    @State private var showAuthorProfile = false
    @State private var page = 0

    private var destName: String { journey.destination?.name ?? journey.place?.name ?? journey.title ?? "Mi viaje" }
    private var authorName: String { (journey.users?.fullName ?? "Buddy").capitalized }
    private var thumbs: [String] {
        let raw = journey.pageThumbs ?? []
        // Sin log aquí: esta propiedad se lee varias veces en cada render
        // (conteo, páginas, indicador…) y el print por lectura era el "5 veces
        // por card" de los logs. Se loguea una vez, al aparecer la card.
        return raw.filter { !$0.isEmpty }
    }
    private var durationLine: String? {
        guard let d = journey.durationDays else { return nil }
        return "en \(d) \(d == 1 ? "día" : "días")"
    }

    // Aspect ratio of the memoir canvas (height ÷ width).
    // Derived once from CanvasViewModel.pageSize — a process-level constant that
    // represents the memoir page format, not a runtime window dimension.
    // Using the ratio (not the absolute values) means the carousel height is always
    // derived from the actual container width at layout time via aspectRatio(_:).
    private let memoirRatio: CGFloat =
        CanvasViewModel.pageSize.height / max(1, CanvasViewModel.pageSize.width)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            carousel
            footer
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .padding(.horizontal, Spacing.edge)
        .sheet(isPresented: $showStory) { StoryViewerSheet(journey: journey) }
        .onAppear { print("🖼️ [StoryCard] aparece id=\(journey.id.prefix(8)) fotos=\(thumbs.count)") }
    }

    // Height is derived from the actual container width via aspectRatio — zero
    // dependency on UIScreen.main.bounds. GeometryReader in the overlay reads the
    // already-resolved frame so content receives exact pixel-perfect dimensions.
    private var carousel: some View {
        Color.clear
            .aspectRatio(1 / memoirRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        carouselMedia(width: geo.size.width, height: geo.size.height)
                        VStack(spacing: 0) {
                            // Scrim: garantiza legibilidad en fotos claras
                            LinearGradient(
                                colors: [.black.opacity(0.38), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(height: 64)
                            Spacer()
                        }
                        VStack(spacing: 0) {
                            HStack {
                                Text(destName)
                                    .font(BT.footnoteBold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 12)
                                Spacer()
                            }
                            Spacer()
                            if thumbs.count > 1 { pageIndicator }
                        }
                    }
                    // Pin ZStack to the resolved frame so it cannot report a larger
                    // layout size back up the tree (guards against any future child
                    // view that might over-expand).
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
            }
            .background(Color(white: 0.96))
            .clipped()
    }

    @ViewBuilder
    private func carouselMedia(width w: CGFloat, height h: CGFloat) -> some View {
        let _ = print("🎠 [carouselMedia] id=\(journey.id.prefix(8)) thumbs=\(thumbs.count) coverUrl=\(journey.destination?.coverUrl ?? "nil")")
        if thumbs.isEmpty {
            // No memoir pages: show destination cover with scaledToFill.
            CachedImage(urlString: journey.destination?.coverUrl) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(colors: [Color.tealDeep, Color.teal],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: w, height: h)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { Haptic.light(); showStory = true }

        } else if thumbs.count == 1 {
            // Single memoir page: plain CachedImage — no TabView, no UIPageViewController,
            // no horizontal UIScrollView in the hierarchy → eliminates the overflow vector.
            CachedImage(urlString: thumbs[0]) { img in
                img.resizable().scaledToFit()
            } placeholder: { Color(white: 0.96) }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onTapGesture { Haptic.light(); showStory = true }

        } else {
            // Multiple memoir pages: TabView with fully pinned width × height so the
            // UIPageViewController never reports an ambiguous contentSize to the ancestor
            // UIScrollView (which is the root cause of the horizontal layout corruption).
            TabView(selection: $page) {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { i, url in
                    CachedImage(urlString: url) { img in
                        img.resizable().scaledToFit()
                    } placeholder: { Color(white: 0.96) }
                    .frame(width: w, height: h)
                    .contentShape(Rectangle())
                    .onTapGesture { Haptic.light(); showStory = true }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: w, height: h)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<thumbs.count, id: \.self) { i in
                Circle()
                    .fill(i == page ? Color.white : Color.white.opacity(0.5))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: page)
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Capsule().fill(.black.opacity(0.28)))
        .padding(.bottom, 10)
    }

    // Pie minimalista: solo viajero + duración (sin destino ni "Ver álbum")
    private var footer: some View {
        HStack(spacing: 8) {
            authorRow
            Spacer(minLength: 4)
            if let d = durationLine {
                Text(d).font(BT.subhead).foregroundStyle(Color.inkMuted)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { Haptic.light(); showStory = true }
        .sheet(isPresented: $showAuthorProfile) {
            if let id = journey.users?.id {
                TravelerProfileView(travelerId: id,
                                    previewName: journey.users?.fullName,
                                    previewAvatarUrl: journey.users?.avatarUrl)
            }
        }
    }

    /// Avatar + nombre. Con id de autor abre su perfil; sin id se comporta
    /// como el resto del pie y abre la historia.
    private var authorRow: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.tealDeep).frame(width: 24, height: 24)
                .overlay {
                    CachedImage(urlString: journey.users?.avatarUrl) { img in
                        img.resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle())
                    } placeholder: {
                        Text(String(authorName.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            Text(authorName)
                .font(BT.footnote)
                .foregroundStyle(Color.ink)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard journey.users?.id != nil else { Haptic.light(); showStory = true; return }
            Haptic.light()
            showAuthorProfile = true
        }
    }
}

// Equatable conformance for .equatable() — journey feed items are immutable snapshots;
// same journey.id + same display flags → skip body re-evaluation when parent re-renders
// (e.g. on every ChatStore.load() / refreshTripState cycle).
extension PublishedTripCard: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.journey.id == rhs.journey.id &&
        lhs.featured == rhs.featured &&
        lhs.matchesMyDestination == rhs.matchesMyDestination &&
        lhs.nearby == rhs.nearby
    }
}

// MARK: – STORY VIEWER (pantalla completa de las páginas del trip)

/// Tarjeta del carrusel "Lugares por aquí". El sujeto es el LUGAR: su foto más
/// reciente, cuántas hay y quién puede ayudarte ahí. No dice quién subió la
/// foto — para el viajero eso no cambia nada; sí importa que haya alguien a
/// quien preguntarle.
struct NearbyPlaceCard: View {
    let place: APIPlaceCard
    /// En el Home el pie son los buddies del destino; en el perfil no hay
    /// buddies que mostrar (el sujeto es lo que aportó esa persona), así que
    /// ahí se pasa el conteo de fotos.
    var subtitleOverride: String? = nil
    /// El padre decide CÓMO abrir el mapa (push en su propio NavigationStack).
    /// Antes esta tarjeta lo hacía con .fullScreenCover, que tapa la tab bar
    /// de la app sin excepción — un push dentro del stack existente no.
    var onTap: () -> Void

    /// Un solo ancho para la imagen y el pie. Cuando el texto llevaba su propio
    /// frame MÁS el padding, la tarjeta terminaba más ancha que la foto y el
    /// fondo asomaba como una franja blanca al costado.
    private let cardWidth: CGFloat = 132
    private let previewHeight: CGFloat = 158
    private let textInset: CGFloat = 12

    var body: some View {
        Button { Haptic.light(); onTap() } label: {
            ZStack(alignment: .bottomLeading) {
                photoPreview

                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.75)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(place.name)
                        .font(BT.footnoteBold)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(alignment: .center, spacing: 6) {
                        if !place.buddies.isEmpty {
                            buddyAvatars
                        }
                        if let label = subtitleOverride ?? place.buddyLabel {
                            let parts = label.components(separatedBy: " en ")
                            VStack(alignment: .leading, spacing: 0) {
                                Text(parts[0])
                                    .font(BT.caption1)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                if parts.count > 1 {
                                    Text("en \(parts[1])")
                                        .font(BT.caption1)
                                        .foregroundStyle(.white.opacity(0.85))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .frame(width: cardWidth - textInset * 2, alignment: .leading)
                .padding(.horizontal, textInset)
                .padding(.vertical, 12)
            }
            .frame(width: cardWidth, height: previewHeight)
            // Pendiente: el lugar ya es tuyo y lo ves, pero la comunidad no
            // hasta que se apruebe. Decirlo evita que parezca publicado.
            .overlay(alignment: .topLeading) {
                if place.isPendingApproval {
                    Text("Pendiente de aprobación")
                        .font(BT.caption2)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.warningAmber.opacity(0.9), in: Capsule())
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Solo la última foto subida del lugar — un vistazo directo, sin mosaico.
    private var photoPreview: some View {
        CachedImage(urlString: place.coverUrl) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(Color.sandLight)
        }
        .frame(width: cardWidth, height: previewHeight)
        .clipped()
    }

    /// Avatares superpuestos + "+N" con los que no caben.
    private var buddyAvatars: some View {
        let shown  = Array(place.buddies.prefix(4))
        let hidden = place.buddyCount - shown.count
        return HStack(spacing: -6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, buddy in
                Group {
                    if let url = buddy.avatarUrl {
                        CachedImage(urlString: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color.sandLight)
                        }
                    } else {
                        Circle().fill(Color.sandLight)
                            .overlay(Text(buddy.initial).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.ink))
                    }
                }
                .frame(width: 18, height: 18)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.surface, lineWidth: 1.5))
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.inkMuted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.sandLight))
                    .overlay(Circle().strokeBorder(Color.surface, lineWidth: 1.5))
            }
        }
    }
}

/// Mapa de UN local, con zoom cerrado en su pin — reutiliza el mismo MapPinView
/// que ya usan la ruta del viajero y el detalle de trip, solo con un span mucho
/// más chico para centrarse en el spot en vez de en toda la ciudad.
/// Abre el MISMO mapa que ya existe para "Tu trip" (TripDetailView: el mapa con
/// pines, "N buddies aquí" y el carrusel "Recomendado por la comunidad") —
/// nada nuevo, solo cargado por destination_id en vez de por journey propio.
///
/// Usa un RouteStore local, dedicado a este sheet: el global vive en el árbol
/// de vistas de "Tu trip" y pisarlo aquí rompería esa pantalla al volver.
struct PlaceGuideMapSheet: View {
    let destinationId: String?
    /// Spot a enfocar dentro de la guía. Nil cuando se abre el destino entero
    /// —desde "Lima" en el subtítulo— y no un lugar puntual.
    let focusPlaceId: String?
    let name: String
    let lat: Double?
    let lng: Double?

    init(destinationId: String?, focusPlaceId: String? = nil, name: String, lat: Double? = nil, lng: Double? = nil) {
        self.destinationId = destinationId
        self.focusPlaceId  = focusPlaceId
        self.name          = name
        self.lat           = lat
        self.lng           = lng
    }

    init(place: APIPlaceCard) {
        self.init(destinationId: place.destinationId, focusPlaceId: place.id,
                  name: place.name, lat: place.lat, lng: place.lng)
    }

    @StateObject private var routeStore = RouteStore()
    @State private var loadState: MapLoadState = .loading
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) { closeButton }
            case .guideAvailable:
                // TripDetailView ya trae su propio botón de volver (chevron
                // flotante sobre el mapa) — no hace falta agregar otro.
                TripDetailView(route: routeStore.route, destinationId: destinationId, focusPlaceId: focusPlaceId)
                    .environmentObject(routeStore)
            case .noGuide(let lat, let lng):
                MapPinView(name: name, lat: lat, lng: lng, span: 0.003)
                    .overlay(alignment: .topLeading) { closeButton }
            case .noData:
                fallbackMessage("No tenemos la ubicación de este lugar", icon: "mappin.slash")
                    .overlay(alignment: .topLeading) { closeButton }
            case .error:
                fallbackMessage("No pudimos cargar el mapa", icon: "wifi.exclamationmark")
                    .overlay(alignment: .topLeading) { closeButton }
            }
        }
        .task {
            guard let destId = destinationId else {
                loadState = lat != nil && lng != nil
                    ? .noGuide(lat: lat!, lng: lng!) : .noData
                return
            }
            loadState = await routeStore.ensureLoaded(destinationId: destId)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.ink)
                .frame(width: 32, height: 32)
                .background(.thinMaterial, in: Circle())
        }
        .padding(.leading, Spacing.edge)
        .padding(.top, Spacing.md)
    }

    private func fallbackMessage(_ text: String, icon: String) -> some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color.inkMuted)
            Text(text).font(BT.callout).foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}

struct StoryViewerSheet: View {
    let journey: APIJourney
    @Environment(\.dismiss) private var dismiss
    @State private var thumbs: [String] = []
    @State private var current = 0

    private var destName: String { journey.destination?.name ?? journey.place?.name ?? journey.title ?? "Mi viaje" }

    var body: some View {
        ZStack(alignment: .top) {
            Color.canvas.ignoresSafeArea()

            if thumbs.isEmpty {
                CachedImage(urlString: journey.destination?.coverUrl) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    LinearGradient(colors: [Color.tealDeep, Color.teal],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $current) {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { i, url in
                        CachedImage(urlString: url) { img in
                            img.resizable().scaledToFit()
                        } placeholder: { Color.sandLight }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .clipped()
                .overlay(alignment: .bottom) {
                    if thumbs.count > 1 {
                        HStack(spacing: 7) {
                            ForEach(0..<thumbs.count, id: \.self) { i in
                                Circle()
                                    .fill(i == current ? Color.ink : Color.ink.opacity(0.25))
                                    .frame(width: 7, height: 7)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: current)
                        .padding(.vertical, 10).padding(.horizontal, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                    }
                }
            }

            // Solo el botón de cerrar — sin conteos. Material para verse sobre
            // foto o sobre el fondo crema indistintamente.
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                        .frame(width: 36, height: 36).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.edge).padding(.top, 8)
        }
        .task {
            // El feed (trips) ya trae page_thumbs agregados de todos los lugares.
            // Si no vienen (p. ej. tab Yo con id de journey real), se piden al server.
            if let pt = journey.pageThumbs, !pt.isEmpty {
                thumbs = pt
            } else {
                thumbs = (try? await APIClient.shared.fetchJourneyPages(journeyId: journey.id))?
                    .map(\.thumbnailUrl) ?? []
            }
            ImagePrefetcher.prefetch(thumbs)
        }
    }
}

// MARK: – COMMUNITY POST

struct CommunityPost: Identifiable {
    let id = UUID()
    let authorName: String
    let authorAvatar: String
    let location: String
    let timeAgo: String
    let coverEmoji: String
    let gradientColors: [Color]
    let likes: Int

    // Real posts loaded from API — empty until backend provides data
    static let live: [CommunityPost] = []
}

// MARK: – COMMUNITY POST CARD
// Editorial photo card. Apple Journal–inspired. No floating badges.

struct CommunityPostCard: View {
    let post: CommunityPost

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: post.gradientColors,
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .frame(height: 240)
                .overlay {
                    Text(post.coverEmoji).font(.system(size: 72))
                }

                // Author — subtle frosted pill
                HStack(spacing: Spacing.sm) {
                    Circle()
                        .fill(.black.opacity(0.22))
                        .frame(width: 32, height: 32)
                        .overlay { Text(post.authorAvatar).font(.system(size: 14)) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.authorName)
                            .font(BT.footnoteBold)
                            .foregroundStyle(.white)
                        Text("\(post.location) · \(post.timeAgo)")
                            .font(BT.caption1)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(Spacing.md)
            }
            .frame(height: 240)
            .clipped()

            HStack {
                Button { Haptic.light() } label: {
                    Label("\(post.likes)", systemImage: "heart")
                        .font(BT.footnote)
                        .foregroundStyle(Color.inkMuted)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.inkMuted.opacity(0.5))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 13)
            .background(Color.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .padding(.bottom, Spacing.md)
    }
}

// MARK: – NEXT TRIP ROW
// Compact strip shown below ActiveTripCard when a planning trip is waiting

struct NextTripRow: View {
    let journey: APIJourney
    var onActivate: () -> Void

    private var destName: String { journey.destination?.name ?? "Próximo destino" }
    private var coverURL: URL? {
        guard let s = journey.destination?.coverUrl else { return nil }
        return URL(string: s)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            CachedImage(url: coverURL) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.sandLight
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("PRÓXIMO VIAJE")
                    .font(BT.eyebrow)
                    .tracking(1)
                    .foregroundStyle(Color.secondary)
                Text(destName)
                    .font(BT.headline)
                    .foregroundStyle(Color.primary)
            }

            Spacer()

            Button {
                Haptic.medium()
                onActivate()
            } label: {
                Text("Activar")
                    .font(BT.footnoteBold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.teal)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .cardShadow()
    }
}

// MARK: – ACTIVE TRIP CARD
// Shown in Inicio when user has a journey with status "active"

struct ActiveTripCard: View {
    let journey: APIJourney
    var match: APIMatch? = nil
    var pendingReply: Bool = false
    var statusText: String = "EN CURSO"
    // Prueba social: buddies que ayudaron en este destino (estado sin buddy)
    var recentHelperName: String? = nil
    var recentHelperTimeAgo: String? = nil
    var recentHelperAvatars: [String?] = []   // urls para el cluster
    var recentHelperTotal: Int = 0
    var onContactBuddy: (() -> Void)? = nil
    var onOpenDetail: (() -> Void)? = nil

    private var coverURL: URL? {
        guard let s = journey.destination?.coverUrl else { return nil }
        return URL(string: s)
    }
    private var tripTitle: String {
        journey.destination?.name ?? journey.title ?? "Tu trip"
    }
    private var buddyName: String {
        TravelerAlias.shortDisplayName(realName: match?.buddy?.fullName,
                                       id: match?.buddy?.id ?? match?.buddyId)
    }
    private var buddyAvatarURL: URL? {
        guard let s = match?.buddy?.avatarUrl else { return nil }
        return URL(string: s)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {

                // Foto de fondo
                CachedImage(url: coverURL) { img in
                    img.resizable().scaledToFill()
                } placeholder: { fallback }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                // Gradiente inferior
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center, endPoint: .bottom
                )

                // Tap zone: imagen/mapa → TripDetail
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { Haptic.light(); onOpenDetail?() }

                // Top bar: EN CURSO badge (top-right)
                HStack {
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(Color.onlineGreen).frame(width: 6, height: 6)
                        Text(statusText)
                            .font(BT.eyebrow)
                            .tracking(1)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // Título + panel inferior
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(tripTitle)
                        .font(BT.title1)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // ── Layout único: prueba social (izq) + círculo de acción (der) ──
                    HStack(spacing: 12) {
                        // Actividad de la comunidad — solo si existe (sin texto de relleno)
                        if let helper = recentHelperName {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: -8) {
                                    ForEach(Array(recentHelperAvatars.prefix(3).enumerated()), id: \.offset) { _, s in
                                        socialAvatar(urlString: s)
                                    }
                                    if recentHelperTotal > 3 {
                                        Text("+\(recentHelperTotal - 3)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 26, height: 26)
                                            .background(.ultraThinMaterial, in: Circle())
                                            .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1.5))
                                    }
                                }
                                (Text(helper).font(BT.footnoteBold).foregroundStyle(.white)
                                 + Text(" ayudó aquí").font(BT.footnote).foregroundStyle(.white.opacity(0.8))
                                 + Text(recentHelperTimeAgo.map { " · \($0)" } ?? "").font(BT.caption1).foregroundStyle(.white.opacity(0.6)))
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        // Círculo de acción: foto del buddy (asignado) o ícono (buscar)
                        Button {
                            Haptic.medium()
                            onContactBuddy?()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                if match != nil {
                                    // Foto del buddy asignado → abre el chat
                                    Circle()
                                        .fill(Color.sandLight)
                                        .frame(width: 48, height: 48)
                                        .overlay {
                                            if buddyAvatarURL != nil {
                                                CachedImage(url: buddyAvatarURL) { img in
                                                    img.resizable().scaledToFill()
                                                } placeholder: { Color.sandLight }
                                                .frame(width: 48, height: 48)
                                                .clipShape(Circle())
                                            } else {
                                                Image(systemName: "person.fill")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(Color.sand)
                                            }
                                        }
                                        .overlay(Circle().stroke(.white, lineWidth: 2))
                                    if pendingReply {
                                        Circle()
                                            .fill(Color.errorRed)
                                            .frame(width: 13, height: 13)
                                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                                            .offset(x: 3, y: -3)
                                    }
                                } else {
                                    Image(systemName: "person.wave.2.fill")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(.black)
                                        .frame(width: 48, height: 48)
                                        .background(.white)
                                        .clipShape(Circle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.md)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.78)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .frame(maxHeight: 340)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
    }

    // Avatar pequeño con borde para el cluster de prueba social sobre la foto
    private func socialAvatar(urlString: String?) -> some View {
        Circle()
            .fill(Color.sandLight)
            .frame(width: 26, height: 26)
            .overlay {
                if let s = urlString {
                    CachedImage(urlString: s) { img in
                        img.resizable().scaledToFill()
                    } placeholder: { Color.sandLight }
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sand)
                }
            }
            .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.5))
    }

    private var fallback: some View {
        LinearGradient(colors: [Color.tealDeep, Color.teal],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: – Shared trip arrival phrasing
// Una sola fórmula de fecha para todos los tabs (cohesión).
func tripArrivalLine(_ date: Date?) -> String {
    guard let date else { return "Fecha por confirmar" }
    let cal = Calendar.current
    if cal.isDateInToday(date)    { return "Llegas hoy" }
    if cal.isDateInTomorrow(date) { return "Llegas mañana" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "es_PE")
    f.dateFormat = "d 'de' MMM"
    return "Llegas el \(f.string(from: date))"
}

// MARK: – TRIP HERO BANNER (compartido: Home + Tu trip)
// Foto + scrim superior e inferior + badge + título + fecha. Mismo objeto en todos
// los tabs → la tarjeta del trip se siente "la misma cosa" donde aparezca.

struct TripHeroBanner: View {
    let coverUrl: String?
    let title: String
    let dateLine: String
    var statusText: String? = "PLANIFICADO"
    var statusColor: Color = Color.accent
    var topEyebrow: String? = nil
    var height: CGFloat = 200
    var trailing: (() -> AnyView)? = nil

    var body: some View {
        CachedImage(urlString: coverUrl) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            LinearGradient(colors: [Color.tealDeep, Color.teal],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        // Scrims como overlays acotados al alto de la foto (no se desbordan
        // sobre la tarjeta blanca de abajo).
        .overlay(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.4), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 84)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: .clear,               location: 0.0),
                    .init(color: .black.opacity(0.22), location: 0.5),
                    .init(color: .black.opacity(0.60), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        // Eyebrow + estado
        .overlay(alignment: .top) {
            HStack(alignment: .top) {
                if let topEyebrow {
                    Text(topEyebrow)
                        .font(BT.eyebrow).tracking(1.5)
                        .foregroundStyle(.white)
                }
                Spacer()
                if let statusText {
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText)
                            .font(BT.eyebrow).tracking(1).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial).clipShape(Capsule())
                }
            }
            .padding(.horizontal, Spacing.md).padding(.top, Spacing.md)
        }
        // Título + fecha + acción opcional
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BT.title1).foregroundStyle(.white).lineLimit(1)
                    Text(dateLine)
                        .font(BT.footnoteBold).foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                if let trailing { trailing() }
            }
            .padding(Spacing.md)
        }
        .clipped()
    }
}

// MARK: – BUDDY READINESS ROW (compartido: Home + Tu trip)
// El corazón del producto: alguien ya está listo para recibirte.

struct BuddyReadinessRow: View {
    let count: Int?
    let placeName: String

    var text: String? {
        guard let c = count else { return nil }
        if c <= 0 { return "Siempre que tengas una duda, puedes contactar a un buddy." }
        return c == 1
            ? "1 buddy en \(placeName) disponible si tienes dudas"
            : "\(c) buddies en \(placeName) disponibles si tienes dudas"
    }

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                Circle().fill(Color.onlineGreen).frame(width: 7, height: 7)
                Text(text)
                    .font(BT.subhead.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 13)
        }
    }
}

// MARK: – PENDING TRIP CARD

struct PendingTripCard: View {
    let journey: APIJourney
    var destination: APIDestination? = nil
    var unreadCount: Int = 0
    var onTap: () -> Void = {}
    var onContactBuddy: () -> Void = {}

    @State private var expandedType: PlanSuggType? = nil
    @State private var buddyCount: Int? = nil

    enum PlanSuggType: CaseIterable { case howToGet, lodging }

    private var destName: String { journey.destination?.name ?? "Tu destino" }
    private var arrivalToday: Bool {
        guard let date = journey.arrivalAt else { return true }
        return Calendar.current.isDateInToday(date)
    }
    private var suggestions: [PlanSuggType] {
        var list: [PlanSuggType] = []
        // Show if user needs help OR destination has info configured
        let hasTransport = destination?.transportInfo != nil || (destination?.howToGetThere?.isEmpty == false)
        if !(journey.knowsHowToGet ?? true) || hasTransport { list.append(.howToGet) }
        let hasLodging = destination?.lodgingTips?.isEmpty == false
        if !(journey.hasLodging ?? true) || hasLodging { list.append(.lodging) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // Photo area — tappable → navigates to map
            photoArea
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

            // Readiness humano — la promesa del producto, antes que la logística
            if buddyCount != nil {
                BuddyReadinessRow(count: buddyCount, placeName: destName)
            }

            // Suggestion rows inside the card — un respiro más bajo la foto
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { type in
                        Divider().padding(.leading, 56)
                        suggestionRow(type)
                    }
                }
                .padding(.top, Spacing.sm)
            }
        }
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .cardShadow()
        .task { await loadBuddyCount() }
    }

    private func loadBuddyCount() async {
        let destId = journey.destination?.id ?? journey.destinationId
        guard let destId else { return }
        if let c = try? await APIClient.shared.fetchBuddyCount(destinationId: destId) {
            await MainActor.run { buddyCount = c }
        }
    }

    // MARK: – Photo section

    private var photoArea: some View {
        TripHeroBanner(
            coverUrl: journey.destination?.coverUrl,
            title: destName,
            dateLine: tripArrivalLine(journey.arrivalAt),
            statusText: arrivalToday ? "POR LLEGAR" : "TE ESPERAMOS",
            statusColor: arrivalToday ? Color.warningAmber : Color.accent,
            topEyebrow: "TU TRIP · \(arrivalToday ? "HOY" : "PRÓXIMO")",
            height: 200,
            trailing: {
                AnyView(
                    Button { onContactBuddy() } label: {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44)
                            Image(systemName: "person.wave.2.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .overlay(alignment: .topTrailing) {
                            if unreadCount > 0 {
                                Text("\(min(unreadCount, 99))")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, unreadCount > 9 ? 4 : 0)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Color.errorRed)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                                    .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                )
            }
        )
    }

    // MARK: – Suggestion row

    private func suggestionRow(_ type: PlanSuggType) -> some View {
        let isExpanded = expandedType == type
        return Button {
            Haptic.light()
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedType = isExpanded ? nil : type
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Spacing.sm) {
                    ZStack {
                        Circle().fill(Color.teal.opacity(0.10)).frame(width: 36, height: 36)
                        Image(systemName: type == .howToGet ? "bus.fill" : "house.fill")
                            .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.teal)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(type == .howToGet ? "Cómo llegar" : "Dónde hospedarte")
                            .font(BT.footnoteBold).foregroundStyle(Color.ink)
                        Text(type == .howToGet
                             ? (destination.map { "Tips para llegar a \($0.name)" } ?? "Opciones de transporte")
                             : "Hospedaje recomendado")
                            .font(BT.caption1).foregroundStyle(Color.inkMuted)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                }
                .padding(.horizontal, Spacing.md).padding(.vertical, 12)

                if isExpanded {
                    Divider().padding(.horizontal, Spacing.md)
                    expandedContent(for: type)
                        .padding(Spacing.md)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func expandedContent(for type: PlanSuggType) -> some View {
        if type == .lodging {
            if let text = destination?.lodgingTips, !text.isEmpty {
                Text(text).font(BT.callout).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Próximamente agregaremos esta info.")
                    .font(BT.callout).foregroundStyle(Color.inkMuted)
            }
        } else {
            transportContent
        }
    }

    @ViewBuilder
    private var transportContent: some View {
        if let info = destination?.transportInfo {
            VStack(alignment: .leading, spacing: 12) {
                // Bus
                if let bus = info.bus, bus.enabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("En bus", systemImage: "bus.fill")
                            .font(BT.footnoteBold).foregroundStyle(Color.ink)
                        if let companies = bus.companies, !companies.isEmpty {
                            Text(companies.joined(separator: " · "))
                                .font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        if let duration = bus.duration {
                            Label(duration, systemImage: "clock").font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        if let notes = bus.notes, !notes.isEmpty {
                            Text(notes).font(BT.caption1).foregroundStyle(Color.inkMuted)
                        }
                        if let urlStr = bus.ticketUrl, let url = URL(string: urlStr) {
                            Button { UIApplication.shared.open(url) } label: {
                                Label("Comprar pasaje", systemImage: "ticket.fill")
                                    .font(BT.footnoteBold)
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .background(Color.teal).foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Auto
                if let car = info.car, car.enabled, let routes = car.routes, !routes.isEmpty {
                    if info.bus?.enabled == true { Divider() }
                    VStack(alignment: .leading, spacing: 6) {
                        Label("En auto", systemImage: "car.fill")
                            .font(BT.footnoteBold).foregroundStyle(Color.ink)
                        ForEach(routes, id: \.name) { route in
                            HStack(alignment: .top, spacing: 6) {
                                Circle().fill(Color.teal).frame(width: 5, height: 5).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(route.name).font(BT.footnoteBold).foregroundStyle(Color.ink)
                                    Text(route.description).font(BT.caption1).foregroundStyle(Color.inkMuted)
                                }
                            }
                        }
                    }
                }

                // Buddy help
                if info.buddyHelp == true {
                    if info.bus?.enabled == true || info.car?.enabled == true { Divider() }
                    HStack(spacing: 8) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 13)).foregroundStyle(Color.teal)
                        Text("¿Necesitas ayuda? Chatea con un buddy")
                            .font(BT.footnoteBold).foregroundStyle(Color.teal)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.inkMuted)
                    }
                }
            }
        } else if let text = destination?.howToGetThere, !text.isEmpty {
            Text(text).font(BT.callout).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Próximamente agregaremos esta info.")
                .font(BT.callout).foregroundStyle(Color.inkMuted)
        }
    }
}



// MARK: – REGISTER TRIP SHEET

struct RegisterTripSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text("¿A dónde vas?")
                    .font(BT.displayLarge)
                    .foregroundStyle(Color.ink)
                Text("Cuéntanos tu destino y te conectamos con un buddy antes de que llegues.")
                    .font(BT.callout)
                    .foregroundStyle(Color.inkMuted)
                Spacer()
            }
            .padding(Spacing.edge)
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle("Nuevo destino")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}
