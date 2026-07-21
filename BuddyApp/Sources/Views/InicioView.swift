import SwiftUI
import CoreLocation
import UIKit

// MARK: – INICIO
// Calm, trustworthy dashboard. The user's home base between adventures.

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
    /// Prompt ligero cuando el GPS detecta un destino distinto al trip activo.
    @State private var locationPromptDestination: APIDestination? = nil
    /// Resolución de ubicación del backend (LocationResolver: polígono → radio).
    /// Única fuente de verdad para "Estás en X" y el destino del CTA del Home.
    /// Reemplaza al viejo nearestDestination (5 destacados + radio 50 km), que
    /// podía elegir un destino vecino equivocado (ej: La Merced estando en Villa Rica).
    @State private var resolvedLocation: APILocationResolution? = nil
    /// Ciudad GPS para el banner cuando no hay destino curado cerca (flujo pioneer).
    @State private var locationPromptCity: String? = nil
    @State private var destinations: [APIDestination] = []
    @State private var pendingJourney: APIJourney? = nil
    @State private var activeJourney: APIJourney? = nil
    @State private var liveJourneys: [APIJourney] = []   // active + planning, para swipe
    @State private var currentTripPage = 0
    @State private var activeMatch: APIMatch? = nil
    @State private var pioneerConfirmation: String? = nil   // banner tras auto-crear request en lugar sin buddies
    /// Chat abierto desde la card "Tu buddy asignado" (paridad con Android).
    @State private var homeChatTarget: ChatStore.ConnectionItem? = nil
    @State private var showPublishSuccessToast = false
    @State private var isLoadingData = true
    @State private var loadDataFailed = false
    @State private var loadDataTask: Task<Void, Never>? = nil
    @State private var refreshStateTask: Task<Void, Never>? = nil
    @State private var publicJourneys: [APIJourney] = []
    @State private var feedCursor: String? = nil
    @State private var feedHasMore = true
    @State private var isLoadingMoreFeed = false
    @State private var seenStoryIds = Set<String>()
    @State private var recentHelp: [APIRecentHelp] = []   // comunidad viva (destino activo)
    @State private var communityPulse: [APIPulseItem] = [] // pulso global (fallback sin actividad local)
    @State private var recentHelpByDest: [String: [APIRecentHelp]] = [:]  // por cada trip vivo
    @State private var isLoadingRecentHelp = false        // anti re-entrada
    @State private var recentHelpDestId: String? = nil    // último destino cargado
    @State private var recentHelpLoadedAt: Date? = nil    // throttle de refetch
    @State private var lastRefreshTripStateAt: Date? = nil // throttle scenePhase refresh (30s)
    @State private var lastCommunityContextLocation: CLLocation? = nil // gate GPS → resolve
    @State private var lastCommunityContextAt: Date? = nil
    @State private var communityPulseLoadedAt: Date? = nil
    @State private var pendingNavToDetail = false
    @State private var hasLoaded = false
    @State private var showActivateNextTripAlert = false
    @State private var skipNextRefresh = false
    @State private var isLoadingFeed = true
    @State private var feedFailed = false
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

    // Destino activo → para pedir el head de afinidad al feed (ranking en servidor)
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
                initialRequest: item.seed
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
        // GPS cambió y el destino detectado difiere del trip activo → prompt ligero.
        // NUNCA se crea un trip en silencio: solo si el usuario confirma.
        .onChange(of: locationService.userLocation) { _, loc in
            // CLLocation es clase: cada fix del GPS es instancia nueva aunque el
            // usuario no se haya movido, así que este onChange dispara en cada
            // tick. Gate por distancia/tiempo para no re-resolver en cada fix.
            guard let loc else { return }
            let moved = lastCommunityContextLocation.map { loc.distance(from: $0) } ?? .greatestFiniteMagnitude
            let age = Date().timeIntervalSince(lastCommunityContextAt ?? .distantPast)
            guard moved > 100 || age > 60 else { return }
            lastCommunityContextLocation = loc
            lastCommunityContextAt = Date()
            evaluateLocationPrompt()
            Task { await refreshHomeCommunityContext() }
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

    /// Mantiene el banner actualizado con el destino detectado por GPS.
    /// Se muestra si el lugar detectado NO está entre tus trips vivos (active o
    /// planning) — así sugiere pedir ayuda donde estás aunque tu trip sea otro.
    /// Banner "Parece que estás en X": aparece cuando el usuario tiene trips vivos
    /// pero su ubicación FÍSICA actual no corresponde a ninguno de ellos.
    /// El cálculo de "¿estoy en el destino?" lo hace el backend (PostGIS).
    /// Cliente solo: consulta is_point_in_destination(lat, lng, destId) RPC.
    private func evaluateLocationPrompt() {
        locationPromptDestination = nil
        locationPromptCity = nil
        guard let loc = locationService.userLocation, !liveJourneys.isEmpty else {
            print("📍 [LocationPrompt] → oculto — userLoc=\(locationService.userLocation != nil) liveJourneys=\(liveJourneys.count)")
            return
        }

        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        let currentPlace = locationService.currentDistrict ?? locationService.currentCity ?? "desconocido"

        print("📍 [LocationPrompt] pos=(\(String(format: "%.4f", lat)), \(String(format: "%.4f", lng))) — lugar=\(currentPlace)")

        // Consultar backend: ¿estoy en alguno de mis trips?
        // El backend responde true/false usando PostGIS (ST_Contains para polygons,
        // ST_DWithin para radius). Cada destino define su escala, no el cliente.
        Task {
            var nearSomeTrip = false
            var checkedTrips: [String] = []

            for journey in liveJourneys {
                guard let destId = journey.destination?.id ?? journey.destinationId else { continue }
                let destName = journey.destination?.name ?? "·"
                checkedTrips.append(destName)

                do {
                    let result = try await APIClient.shared.callRPC(
                        "is_point_in_destination",
                        params: [
                            "p_lat": lat,
                            "p_lng": lng,
                            "p_destination_id": destId
                        ]
                    )
                    if let isInside = result as? Bool, isInside {
                        print("📍 [LocationPrompt] trip=\(destName) → ✅ aquí (backend)")
                        nearSomeTrip = true
                        break
                    }
                } catch {
                    print("📍 [LocationPrompt] RPC error para \(destName): \(error)")
                }
            }

            await MainActor.run {
                if nearSomeTrip {
                    print("📍 [LocationPrompt] → oculto — ya estás en tu trip (checked: \(checkedTrips.joined(separator: ", ")))")
                    return
                }

                // Estoy fuera de todos mis trips: sugerir ayuda AQUÍ
                print("📍 [LocationPrompt] fuera de todos los trips (checked: \(checkedTrips.joined(separator: ", ")))")
                if let resolved = resolvedLocation,
                   let near = destinations.first(where: { $0.id == resolved.destinationId }) {
                    // Solo si el destino resuelto por el backend está en catálogo local;
                    // si no, el banner usa el nombre resuelto como ciudad GPS.
                    locationPromptDestination = near
                    print("📍 [LocationPrompt] → mostrar destino curado: \(near.name)")
                } else if let resolvedName = resolvedLocation?.destinationName {
                    locationPromptCity = resolvedName
                    print("📍 [LocationPrompt] → mostrar destino resuelto: \(resolvedName)")
                } else if let place = locationService.currentDistrict ?? locationService.currentCity {
                    locationPromptCity = place
                    print("📍 [LocationPrompt] → mostrar lugar GPS: \(place)")
                } else {
                    print("📍 [LocationPrompt] → oculto — sin destino curado ni ciudad GPS")
                }
            }
        }
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
        // Si hay un trip activo, usarlo directamente sin importar la ubicación detectada
        if let activeJourney = liveJourneys.first {
            // Pioneer: no hay buddies en este lugar → redirigir al tab Tu trip
            if homeCommunityContext?.totalBuddies == 0 {
                print("📍 [submitHelpFromHome] pioneer con trip activo → Tu trip tab")
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
            print("📍 [submitHelpFromHome] pioneer con destino \(dest.destinationName) → crear trip automático")
            await pioneerHelpFlow(category: category, description: description,
                                  destinationId: dest.destinationId, cityName: dest.destinationName)
            return
        }
        // El destino del CTA es el resuelto por el backend — mismo lugar que el
        // usuario ve en "Estás en X" y en el contador de buddies.
        guard let dest = resolvedLocation else {
            if let loc = locationService.userLocation, homeCommunityContext?.totalBuddies == 0 {
                // Pioneer sin trip: crear el trip + request, luego ir a Tu trip
                print("📍 [submitHelpFromHome] pioneer sin trip + cat=\(category) → crear trip + Tu trip tab")
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
        ScrollViewReader { proxy in
            scrollBody
                .background(Color.canvas)
                // Keyboard pre-warmer lives in BuddyChatView — InicioView has no knowledge
                // of the keyboard. See KeyboardPrewarmer in ContactarBuddyView.swift.
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: APIJourney.self) { journey in
                    TripDetailGate(journey: journey, match: activeMatch, unreadCount: 0)
                        .environmentObject(routeStore)
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
                        let age = Date().timeIntervalSince(lastRefreshTripStateAt ?? .distantPast)
                        guard age >= 10 else { return }
                        Task { await refreshTripState() }
                    }
                }
                .onChange(of: placeDeepLink.pending != nil) { _, hasPending in
                    if hasPending, let journey = activeJourney ?? pendingJourney {
                        navPath = NavigationPath()
                        navPath.append(journey)
                    }
                }
                .refreshable { await loadData() }
                .onChange(of: navPath.count) { old, new in
                    // Al volver de navegación interna solo refrescamos estado del trip
                    // (journeys + match) — loadData completo no es necesario y causa
                    // que el scroll vuelva al top al reasignar publicJourneys.
                    if new == 0 && old > 0 { Task { await refreshTripState() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: .journeyPublished)) { _ in
                    Task { await loadData() }
                    showPublishSuccessToast = true
                    UIAccessibility.post(notification: .announcement, argument: "Historia publicada")
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
                    Task { await loadData() }
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
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("inicioTop", anchor: .top) }
                    Task { await loadData() }
                }
        }
    }

    private var scrollBody: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: 0).id("inicioTop")

                if let dest = locationPromptDestination {
                    LocationPromptBanner(city: dest.city) {
                        requireIdentity {
                            Task { await openHelp(forDestinationId: dest.id) }
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)
                } else if let city = locationPromptCity {
                    // Sin destino curado: flujo pioneer con la ubicación GPS actual
                    LocationPromptBanner(city: city) {
                        requireIdentity {
                            guard let loc = locationService.userLocation else { return }
                            Task { await pioneerHelpFlow(category: "general", description: nil, loc: loc) }
                        }
                    }
                    .padding(.horizontal, Spacing.edge)
                    .padding(.top, Spacing.md)
                }

                if loadDataFailed && !isLoadingData {
                    Button {
                        Task { await loadData() }
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
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            SkeletonBox(cornerRadius: 4).frame(width: 130, height: 14)
                            CategoryPickerView(isSkeleton: true) { _, _ in }
                                .padding(.horizontal, -Spacing.edge)
                            RegisterCTACard(destinations: []) {}
                                .redacted(reason: .placeholder)
                                .disabled(true)
                        }
                        .skeletonPulse()
                    } else if !liveJourneys.isEmpty {
                        activeTripComposer
                    } else {
                        noTripComposer
                    }
                }
                .padding(.horizontal, Spacing.edge)
                .padding(.top, Spacing.md)
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

                // Comunidad viva — actividad local o, en su defecto, el pulso
                // global de la red. La sección vive siempre que haya algo real.
                if !recentHelp.isEmpty || !communityPulse.isEmpty {
                    communityLiveSection
                        .padding(.top, Spacing.xl)
                }

                communitySection
                    .padding(.top, Spacing.xl)
            }
            .padding(.bottom, 100)
        }
    }

    @ViewBuilder private var noTripComposer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            locationContext
            CategoryPickerView(
                buddyCount: homeBuddyCount,
                destinationName: resolvedLocation?.destinationName ?? locationService.currentCity,
                communityContext: homeCommunityContext,
                pioneerRequiresCategory: homeCommunityContext?.totalBuddies == 0,
                isLoading: isFindingBuddy
            ) { cat, desc in
                requireIdentity {
                    guard !isFindingBuddy else { return }
                    isFindingBuddy = true
                    Task {
                        defer { isFindingBuddy = false }
                        await submitHelpFromHome(category: cat, description: desc)
                    }
                }
            }
            .padding(.horizontal, -Spacing.edge)
            .opacity(isFindingBuddy ? 0.5 : 1)
            .disabled(isFindingBuddy)

            RegisterCTACard(destinations: destinations) {
                requireIdentity { navPath.append("register") }
            }
        }
    }

    @ViewBuilder private func stringDestination(route: String) -> some View {
        if route == "register" {
            RegisterTripView { journey in
                print("🧳 [onJourneyCreated] id=\(journey.id.prefix(8)) dest=\(journey.destination?.name ?? journey.destinationId ?? "?") liveJourneys.before=\(liveJourneys.count)")
                navPath = NavigationPath()
                if homeHelpSeed != nil {
                    print("🧳 [onJourneyCreated] path=contactSheet — seteando activeJourney directo")
                    confirmedHelpSeed = homeHelpSeed
                    homeHelpSeed = nil
                    activeJourney = journey
                    lastContactSheetJourney = journey
                    contactSheetJourney = journey
                } else {
                    print("🧳 [onJourneyCreated] path=switchToTrips — liveJourneys sigue en \(liveJourneys.count)")
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

    @ViewBuilder private var activeTripComposer: some View {
        let activeDest = liveJourneys.first?.destination?.name ?? liveJourneys.first?.place?.name
        let activeJrn  = liveJourneys.first
        VStack(alignment: .leading, spacing: Spacing.xs) {
            CategoryPickerView(
                buddyCount: homeBuddyCount,
                destinationName: activeDest,
                onDestinationTap: {
                    if let j = activeJrn { navPath.append(j) }
                },
                activeBuddyName: activeMatch.flatMap { m in
                    ["accepted", "active", "pending"].contains(m.status)
                        ? m.buddy?.fullName?.components(separatedBy: " ").first?.capitalized
                        : nil
                },
                activeBuddyAvatarUrl: activeMatch.flatMap { m in
                    ["accepted", "active", "pending"].contains(m.status) ? m.buddy?.avatarUrl : nil
                },
                communityContext: homeCommunityContext,
                isLoading: isFindingBuddy
            ) { cat, desc in
                requireIdentity {
                    guard !isFindingBuddy else { return }
                    isFindingBuddy = true
                    Task {
                        defer { isFindingBuddy = false }
                        await submitHelpFromHome(category: cat, description: desc)
                    }
                }
            }
            .padding(.horizontal, -Spacing.edge)
            .opacity(isFindingBuddy ? 0.5 : 1)
            .disabled(isFindingBuddy)

            assignedBuddyCard

            // "¿Vas a viajar?" solo aplica sin trip — este composer es el del
            // trip activo, así que la card de registro se omite aquí.
        }
    }

    // MARK: – Assigned buddy card (paridad con AssignedBuddyCard de Android)

    /// Card "Tu buddy asignado" bajo el composer: avatar + badge de no leídos,
    /// último mensaje con prefijo "Tú:" y tap → chat directo. Mismas reglas que
    /// Android: visible solo con match del viajero en accepted/active/pending.
    @ViewBuilder private var assignedBuddyCard: some View {
        if let match = activeMatch,
           ["accepted", "active", "pending"].contains(match.status) {
            let conn = chatStore.connections.first { $0.id == match.id }
            let name = match.buddy?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Buddy"
            Button {
                if let conn { homeChatTarget = conn } else { router.switchTo(.conexiones) }
            } label: {
                HStack(spacing: Spacing.md) {
                    ZStack(alignment: .topTrailing) {
                        Circle()
                            .fill(Color.surfaceRaised)
                            .frame(width: 44, height: 44)
                            .overlay {
                                if let urlStr = match.buddy?.avatarUrl, let url = URL(string: urlStr) {
                                    AsyncImage(url: url) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: { Color.surfaceRaised }
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(Color.inkMuted)
                                }
                            }
                        // Punto rojo = pendiente de respuesta — misma regla que
                        // el badge del tab Conexiones (pendingReply), no read_at.
                        if conn?.pendingReply == true {
                            Text("1")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.errorRed, in: Circle())
                                .offset(x: 4, y: -4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        (Text("Tu buddy asignado ")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.inkMuted)
                         + Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.ink))
                            .lineLimit(1)
                        if let conn, conn.lastMessage != nil {
                            Text(conn.isLastFromMe ? "Tú: \(conn.lastText)" : conn.lastText)
                                .font(BT.caption1)
                                .foregroundStyle(Color.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.brand)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, 10)
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(Color.brand.opacity(0.25), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func refreshHomeCommunityContext() async {
        // Si hay un trip activo, cargar el contexto de su destino o lugar
        if let j = liveJourneys.first {
            print("🏠 [refreshHomeCommunityContext] active trip — loading context")
            if let destId = j.destination?.id ?? j.destinationId,
               let ctx = try? await APIClient.shared.fetchPlaceContext(id: destId, source: "destination") {
                await MainActor.run { homeCommunityContext = ctx; homeBuddyCount = ctx.buddies }
                print("🏠 [refreshHomeCommunityContext] ✅ loaded from destination: buddies=\(ctx.buddies)")
            } else if let placeId = j.placeId,
                      let ctx = try? await APIClient.shared.fetchPlaceContext(id: placeId, source: "place") {
                await MainActor.run { homeCommunityContext = ctx; homeBuddyCount = ctx.buddies }
                print("🏠 [refreshHomeCommunityContext] ✅ loaded from place: buddies=\(ctx.buddies)")
            } else {
                await MainActor.run {
                    homeCommunityContext = APIPlaceContext(buddies: 0, totalBuddies: 0, stories: 0, status: "pioneer")
                    homeBuddyCount = 0
                }
                print("🏠 [refreshHomeCommunityContext] ❌ no context found — pioneer mode")
            }
            return
        }
        // Sin trip activo — el backend resuelve el destino real (polígono → radio).
        // Nunca la lista de 5 destacados: elegía el vecino equivocado
        // (ej: "Estás en La Merced" estando en Villa Rica).
        if let loc = locationService.userLocation {
            let lat = loc.coordinate.latitude
            let lng = loc.coordinate.longitude
            print("🏠 [refreshHomeCommunityContext] no trip — resolving location: lat=\(String(format: "%.4f", lat)) lng=\(String(format: "%.4f", lng))")

            // LocationResolverService en backend: polígonos → radio → nil
            if let resolution = try? await APIClient.shared.resolveLocation(lat: lat, lng: lng) {
                print("🏠 [refreshHomeCommunityContext] ✅ resolved: \(resolution.destinationName) (\(resolution.matchedBy), \(resolution.distanceMeters)m)")
                await MainActor.run { resolvedLocation = resolution }
                // Con el destino resuelto ya se puede cargar "Comunidad viva"
                // aunque no exista trip (loadRecentHelp usa resolvedLocation).
                await loadRecentHelp()
                await loadCommunityPulseIfNeeded()

                // Cargar contexto de la comunidad de este destino
                if let ctx = try? await APIClient.shared.fetchPlaceContext(id: resolution.destinationId, source: "destination") {
                    await MainActor.run { homeCommunityContext = ctx; homeBuddyCount = ctx.buddies }
                    print("🏠 [refreshHomeCommunityContext] ✅ loaded context: buddies=\(ctx.buddies)")
                    return
                }
            } else {
                print("🏠 [refreshHomeCommunityContext] ⚠️  no location match")
                await MainActor.run { resolvedLocation = nil }
            }

            // Sin match: pioneer mode
            await MainActor.run {
                homeCommunityContext = APIPlaceContext(buddies: 0, totalBuddies: 0, stories: 0, status: "pioneer")
                homeBuddyCount = 0
            }
            print("🏠 [refreshHomeCommunityContext] → pioneer mode (0 buddies)")
        } else {
            print("🏠 [refreshHomeCommunityContext] no location — skipping")
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
    private func refreshTripState() async {
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
        guard let journeys = try? await APIClient.shared.fetchTravelerJourneys() else {
            print("❌ [refreshTripState] fetchTravelerJourneys falló")
            return
        }
        print("🔄 [refreshTripState] \(journeys.count) journey(s): \(journeys.map { "\($0.destination?.name ?? "?"):\($0.status ?? "nil")" })")
        let active   = journeys.first(where: { $0.status == "active" })
        let planning = journeys.first(where: { $0.status == "planning" })

        // Recalcular el match activo — al cerrar un apoyo el match deja de estar
        // en estados activos, así el card vuelve a mostrar el ícono (no la foto).
        var resolvedMatch: APIMatch? = nil
        if active != nil {
            let matches = (try? await APIClient.shared.fetchMatches()) ?? []
            let myId = Session.travelerId
            resolvedMatch = matches.first(where: {
                ["accepted", "active", "pending"].contains($0.status) && $0.travelerId == myId
            })
        }

        await MainActor.run {
            activeJourney  = active
            pendingJourney = planning
            activeMatch    = resolvedMatch
            liveJourneys   = journeys
                .filter { ["active", "planning"].contains($0.status) }
                .sorted { ($0.status == "active" ? 0 : 1) < ($1.status == "active" ? 0 : 1) }
            evaluateLocationPrompt()
            print("🔄 [refreshTripState] ✅ state written — activeJourney=\(active?.id.prefix(8) ?? "nil") liveJourneys=\(liveJourneys.count)")
        }
        await loadRecentHelp()
        await loadRecentHelpPerTrip()
        await loadCommunityPulseIfNeeded()
        await refreshHomeCommunityContext()
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
            let matches = try? await APIClient.shared.fetchMatches()
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

    private func loadData() async {
        // Cancel any in-flight loadData — only the latest matters.
        loadDataTask?.cancel()
        let task = Task<Void, Never> { [self] in await _loadDataBody() }
        loadDataTask = task
        await task.value
    }

    private func _loadDataBody() async {
        guard !Task.isCancelled else { return }
        await MainActor.run { loadDataFailed = false }
        // ── Contenido PÚBLICO: siempre carga, sin importar la sesión ──
        async let dests = APIClient.shared.fetchDestinations()
        let fetchedDests = (try? await dests) ?? []
        await MainActor.run {
            destinations = fetchedDests
            ImagePrefetcher.prefetch(destinations.compactMap { $0.coverUrl })
            evaluateLocationPrompt()
        }

        // Sin ninguna sesión (ni guest ni verified): solo contenido público.
        let tid = Session.travelerId
        print("🏠 [loadData] hasSession=\(Session.hasSession) travelerId=\(tid?.prefix(8) ?? "nil") isVerified=\(Session.isVerified)")
        guard Session.hasSession else {
            print("🏠 [loadData] sin sesión — solo contenido público")
            await MainActor.run { isLoadingData = false }
            await loadFeed()
            await refreshHomeCommunityContext()
            return
        }
        // ── Contenido PRIVADO: guest y verified cargan sus journeys ──

        do {
            // fetchTravelerJourneys usa el JWT (traveler o Supabase) — válido para ambos.
            let snapshotId = Session.travelerId   // capturar ANTES del await
            print("🏠 [loadData] fetching journeys para travelerId=\(snapshotId?.prefix(8) ?? "nil")…")
            let journeys = try await APIClient.shared.fetchTravelerJourneys()
            guard !Task.isCancelled else { return }
            print("🏠 [loadData] \(journeys.count) journey(s) recibidos: \(journeys.map { "\($0.destination?.name ?? "?"):\($0.status ?? "nil")" })")
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
            print("🏠 [loadData] active=\(active?.id.prefix(8) ?? "nil") planning=\(planning?.id.prefix(8) ?? "nil")")

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
                evaluateLocationPrompt()
                print("🏠 [loadData] ✅ state written — activeJourney=\(active?.id.prefix(8) ?? "nil") liveJourneys=\(newLive.count)")
            }

            let shouldFetchMatch = await MainActor.run { activeJourney != nil }
            if shouldFetchMatch {
                let matches = try await APIClient.shared.fetchMatches()
                guard !Task.isCancelled else { return }
                print("🏠 [loadData] \(matches.count) match(es): \(matches.map { "\($0.status ?? "?")" })")
                // Must filter by travelerId: user may simultaneously be a buddy for
                // another traveler, and fetchMatches() returns matches in both roles.
                // Without this guard, the buddy-role match can win the .first() and
                // the home shows the user's own name in the "Hablar con tu buddy" card.
                let myId = Session.travelerId
                let found = matches.first(where: {
                    ["accepted", "active", "pending"].contains($0.status) && $0.travelerId == myId
                })
                await MainActor.run { activeMatch = found }
                await chatStore.load()
            }
            await loadRecentHelp(force: true)
            await loadRecentHelpPerTrip()
        } catch {
            print("❌ [loadData] ERROR: \(error)")
            await MainActor.run { loadDataFailed = true }
        }
        await MainActor.run { isLoadingData = false }
        print("🏠 [loadData] done — activeJourney=\(await MainActor.run { activeJourney?.id.prefix(8) ?? "nil" }) liveJourneys=\(await MainActor.run { liveJourneys.count })")

        // Si viene de "Ya llegué", navegar directo al mapa
        await MainActor.run {
            if pendingNavToDetail, activeJourney != nil, routeStore.isReady {
                pendingNavToDetail = false
                navPath.append("tripDetail")
            }
        }

        // Feed de trips publicados — con un reintento: un timeout puntual
        // no puede dejar la comunidad vacía en silencio
        await loadFeed()

        // Buddies cerca para el composer de la Home (si no hay trip)
        await refreshHomeCommunityContext()
    }

    private var feedLat: Double? { locationService.userLocation?.coordinate.latitude }
    private var feedLng: Double? { locationService.userLocation?.coordinate.longitude }

    // Primera página del feed (cursor pagination + ranking servidor)
    private func loadFeed() async {
        // Solo activar skeleton si no hay datos previos — evita parpadeo en refresh.
        // feedFailed se resetea solo si el request tiene éxito.
        if publicJourneys.isEmpty { isLoadingFeed = true }
        for attempt in 0..<2 {
            do {
                let page = try await APIClient.shared.fetchStories(
                    destinationId: myDestinationId, lat: feedLat, lng: feedLng, cursor: nil)
                print("🗞️ [loadFeed] items=\(page.items.count)")
                for (i, item) in page.items.enumerated() {
                    let thumbs = item.pageThumbs ?? []
                    let dest   = item.destination?.name ?? item.title ?? "nil"
                    let author = item.users?.fullName ?? "nil"
                    print("🗞️ [loadFeed] [\(i)] id=\(item.id.prefix(8)) dest=\(dest) author=\(author) thumbs=\(thumbs.count)")
                    if thumbs.isEmpty {
                        print("🗞️ [loadFeed] [\(i)] ⚠️ SIN THUMBS — mostrará fondo")
                    }
                }
                publicJourneys = page.items
                seenStoryIds = Set(page.items.map(\.id))
                feedCursor = page.nextCursor
                feedHasMore = page.hasMore
                feedFailed = false
                isLoadingFeed = false
                return
            } catch {
                if attempt == 0 { try? await Task.sleep(for: .seconds(1.5)) }
            }
        }
        isLoadingFeed = false
        feedFailed = publicJourneys.isEmpty
    }

    // Carga incremental — se dispara al acercarse al final (scroll infinito)
    private func loadMoreFeed() async {
        guard feedHasMore, !isLoadingMoreFeed, let cursor = feedCursor else { return }
        isLoadingMoreFeed = true
        defer { isLoadingMoreFeed = false }
        guard let page = try? await APIClient.shared.fetchStories(
            destinationId: myDestinationId, lat: feedLat, lng: feedLng, cursor: cursor) else { return }
        // Append + dedupe (los items de afinidad pueden reaparecer en la cola global)
        let fresh = page.items.filter { seenStoryIds.insert($0.id).inserted }
        publicJourneys.append(contentsOf: fresh)
        feedCursor = page.nextCursor
        feedHasMore = page.hasMore
    }

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
        let journey = activeJourney ?? pendingJourney
        // Regla de Comunidad viva: la actividad local SOLO aplica cuando el
        // usuario tiene un trip creado. Sin trip → recentHelp queda vacío y la
        // sección muestra siempre el pulso global (top viajeros por lugar).
        guard let destId = journey?.destination?.id ?? journey?.destinationId else {
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
            let result = try await APIClient.shared.fetchRecentHelp(destinationId: destId)
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
    // "Villa Rica · 3 buddies listos para ayudar". Máx. 3 filas.
    private var communityLiveSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("COMUNIDAD VIVA")
                .font(BT.eyebrow).tracking(1.5)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, Spacing.edge)

            VStack(spacing: 0) {
                if !recentHelp.isEmpty {
                    ForEach(Array(recentHelp.prefix(3).enumerated()), id: \.element.id) { idx, help in
                        if idx > 0 { Divider().padding(.leading, 56) }
                        communityRow(
                            avatarUrl: help.buddy?.avatarUrl,
                            icon: "person.fill",
                            text: Text(help.buddy?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Un buddy")
                                .font(BT.footnoteBold).foregroundStyle(Color.ink)
                             + Text(" ayudó a un viajero").font(BT.footnote).foregroundStyle(Color.inkMuted)
                             + Text(help.completedAt != nil ? " · \(timeAgo(help.completedAt))" : "")
                                .font(BT.caption1).foregroundStyle(Color.inkMuted.opacity(0.7))
                        )
                    }
                } else {
                    ForEach(Array(communityPulse.prefix(3).enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 { Divider().padding(.leading, 56) }
                        communityRow(avatarUrl: nil, icon: pulseIcon(item.type), text: pulseText(item))
                    }
                }
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.border, lineWidth: 1))
            .padding(.horizontal, Spacing.edge)
        }
    }

    @ViewBuilder
    private func communityRow(avatarUrl: String?, icon: String, text: Text) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.sandLight)
                .frame(width: 32, height: 32)
                .overlay {
                    if let urlStr = avatarUrl, let url = URL(string: urlStr) {
                        AsyncImage(url: url) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { Color.sandLight }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.sand)
                    }
                }
            text.lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
    }

    private func pulseIcon(_ type: String) -> String {
        switch type {
        case "traveling": return "figure.walk"
        case "ready":     return "person.2.fill"
        default:          return "person.fill"
        }
    }

    private func pulseText(_ item: APIPulseItem) -> Text {
        switch item.type {
        case "traveling":
            let n = item.count ?? 1
            let prefix = n == 1 ? "Un viajero está en " : "\(n) viajeros están en "
            return Text(prefix).font(BT.footnote).foregroundStyle(Color.inkMuted)
                + Text(item.city).font(BT.footnoteBold).foregroundStyle(Color.ink)
        case "ready":
            let n = item.count ?? 1
            return Text(item.city).font(BT.footnoteBold).foregroundStyle(Color.ink)
                + Text(n == 1 ? " · 1 buddy listo para ayudar" : " · \(n) buddies listos para ayudar")
                    .font(BT.footnote).foregroundStyle(Color.inkMuted)
        default: // helped
            return Text(item.city).font(BT.footnoteBold).foregroundStyle(Color.ink)
                + Text(" · un buddy ayudó a un viajero").font(BT.footnote).foregroundStyle(Color.inkMuted)
                + Text(item.at != nil ? " · \(timeAgo(item.at))" : "")
                    .font(BT.caption1).foregroundStyle(Color.inkMuted.opacity(0.7))
        }
    }

    /// Carga el pulso global solo cuando el destino actual no tiene actividad
    /// propia — la sección nunca queda vacía mientras la red esté viva.
    private func loadCommunityPulseIfNeeded() async {
        guard recentHelp.isEmpty else { return }
        // El pulso global cambia lento — no refetchar en < 60 s.
        if let at = communityPulseLoadedAt, Date().timeIntervalSince(at) < 60, !communityPulse.isEmpty {
            return
        }
        if let pulse = try? await APIClient.shared.fetchCommunityPulse() {
            await MainActor.run { communityPulse = pulse; communityPulseLoadedAt = Date() }
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

    private var communitySection: some View {
        Group {
            if isLoadingFeed && publicJourneys.isEmpty {
                // Skeleton de publicación: mismo layout, mismo orden (foto → footer) y
                // mismo chrome (radio/sombra/padding) que PublishedTripCard real, para
                // que al llegar el feed no haya salto — solo las barras se vuelven texto.
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text("HISTORIAS DE VIAJEROS")
                        .font(BT.eyebrow)
                        .tracking(1.5)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, Spacing.edge)
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonBox(cornerRadius: 0).frame(height: 480)
                        HStack(spacing: 8) {
                            SkeletonBox(cornerRadius: 12).frame(width: 24, height: 24)
                            SkeletonBox(cornerRadius: 4).frame(width: 100, height: 13)
                            Spacer(minLength: 4)
                            SkeletonBox(cornerRadius: 4).frame(width: 50, height: 12)
                        }
                        .padding(14)
                    }
                    .background(Color.surface)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .cardShadow()
                    .padding(.horizontal, Spacing.edge)
                }
                .skeletonPulse()
            } else if feedFailed {
                // El feed falló tras reintentos — se dice y se ofrece reintentar
                VStack(spacing: Spacing.sm) {
                    Text("No pudimos cargar la comunidad")
                        .font(BT.callout)
                        .foregroundStyle(Color.inkMuted)
                    Button {
                        isLoadingFeed = true
                        Task { await loadFeed() }
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
            } else if !publicJourneys.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text("HISTORIAS DE VIAJEROS")
                        .font(BT.eyebrow)
                        .tracking(1.5)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, Spacing.edge)

                    // Biblioteca de viajes — orden y ranking vienen del servidor.
                    // Scroll infinito: al acercarse al final, carga el siguiente lote.
                    ForEach(publicJourneys) { journey in
                        PublishedTripCard(journey: journey)
                            .equatable()  // skip re-render if journey.id + flags unchanged
                            .onAppear {
                                if journey.id == publicJourneys.suffix(4).first?.id {
                                    Task { await loadMoreFeed() }
                                }
                            }
                    }
                    if isLoadingMoreFeed {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.md)
                    }
                }
            } else {
                // Estado vacío — diario, no feed
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text("HISTORIAS DE VIAJEROS")
                        .font(BT.eyebrow).tracking(1.5).foregroundStyle(Color.ink)
                        .padding(.horizontal, Spacing.edge)
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 38, weight: .light))
                            .foregroundStyle(Color.inkMuted.opacity(0.5))
                        Text("Aún nadie ha contado su paso por aquí")
                            .font(BT.callout).foregroundStyle(Color.ink)
                        Text("Cuando termines tu trip, tu historia será la primera.")
                            .font(BT.footnote).foregroundStyle(Color.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xl)
                    .padding(.horizontal, Spacing.edge)
                }
            }
        }
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
            print("🗺️ [TripDetailGate] journey=\(journey.id.prefix(8)) dest=\(journey.destination?.name ?? "nil") placeId=\(journey.placeId ?? "nil") → mapState=\(state)")
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

    init(name: String, lat: Double, lng: Double) {
        self.name = name
        self.lat  = lat
        self.lng  = lng
        _region = State(initialValue: MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
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

// Carries both pieces the home-help sheet needs atomically.
// Using this as the .sheet(item:) driver eliminates the Bool/optional
// desync that caused blank screens on first open.
struct HomeHelpItem: Identifiable {
    let id = UUID()
    let destinationId: String
    let seed: (category: String, description: String?)?
    var journey: APIJourney? = nil
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

struct PublishedTripCard: View {
    let journey: APIJourney
    var featured: Bool = false
    var matchesMyDestination: Bool = false
    var nearby: Bool = false

    @State private var showStory = false
    @State private var page = 0

    private var destName: String { journey.destination?.name ?? journey.place?.name ?? journey.title ?? "Mi viaje" }
    private var authorName: String { (journey.users?.fullName ?? "Buddy").capitalized }
    private var thumbs: [String] {
        let raw = journey.pageThumbs ?? []
        let filtered = raw.filter { !$0.isEmpty }
        print("🖼️ [StoryCard] id=\(journey.id.prefix(8)) pageThumbs.raw=\(raw.count) filtered=\(filtered.count) urls=\(filtered)")
        return filtered
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
            Circle().fill(Color.tealDeep).frame(width: 24, height: 24)
                .overlay {
                    CachedImage(urlString: journey.users?.avatarUrl) { img in
                        img.resizable().scaledToFill().frame(width: 24, height: 24).clipShape(Circle())
                    } placeholder: {
                        Text(String(authorName.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    }
                }
            Text(authorName).font(BT.footnote).foregroundStyle(Color.ink)
            Spacer(minLength: 4)
            if let d = durationLine {
                Text(d).font(BT.subhead).foregroundStyle(Color.inkMuted)
            }
        }
        .padding(14)
        .contentShape(Rectangle())
        .onTapGesture { Haptic.light(); showStory = true }
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

// MARK: – LOCATION PROMPT BANNER
// Inline card shown above the trip card when GPS detects a different destination

struct LocationPromptBanner: View {
    let city: String
    var onConfirm: () -> Void

    var body: some View {
        Button {
            Haptic.light()
            onConfirm()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.teal)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Parece que estás en \(city)")
                        .font(BT.footnote)
                        .foregroundStyle(Color.primary)
                    Text("Buscar un buddy aquí")
                        .font(BT.caption1)
                        .foregroundStyle(Color.teal)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 12)
            .background(Color.teal.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(Color.teal.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
        match?.buddy?.fullName?.components(separatedBy: " ").first?.capitalized ?? "Buddy"
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
