import SwiftUI

struct TripConfirmView: View {
    let journey: APIJourney
    let buddyCount: Int
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var routeStore: RouteStore
    @State private var isActivating = false

    private var destination: APIDestinationRef? { journey.destination }

    var body: some View {
        ZStack(alignment: .bottom) {

            // MARK: Full-screen hero
            GeometryReader { geo in
                CachedImage(urlString: destination?.coverUrl) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    heroFallback
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .ignoresSafeArea()

            // MARK: Bottom gradient — strong so text is always readable
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.08), location: 0),
                    .init(color: .black.opacity(0.30), location: 0.35),
                    .init(color: .black.opacity(0.72), location: 0.65),
                    .init(color: .black.opacity(0.88), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // back button is provided by NavigationStack

            // MARK: Bottom sheet content
            VStack(alignment: .leading, spacing: 0) {

                // Eyebrow + title
                Text("TU NUEVO TRIP")
                    .font(BT.eyebrow)
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 6)

                Text(destination?.name ?? "Tu destino")
                    .font(BT.displayXL)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                // Info chips
                HStack(spacing: 8) {
                    glassChip(icon: "mappin.circle.fill", text: destination?.city ?? "Perú")
                    glassChip(icon: "calendar", text: arrivalLabel)
                }
                .padding(.top, Spacing.md)

                // Buddy count — liquid glass card
                HStack(spacing: Spacing.md) {
                    // Stacked avatars
                    ZStack(alignment: .leading) {
                        ForEach(0..<min(3, max(buddyCount, 0)), id: \.self) { i in
                            Circle()
                                .fill(.white.opacity(0.25))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1.5))
                                .offset(x: CGFloat(i) * 20)
                        }
                    }
                    .frame(width: CGFloat(min(max(buddyCount, 0), 3)) * 20 + 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(buddyCount)")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                            Text("buddies cerca")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        HStack(spacing: 5) {
                            Circle().fill(Color.onlineGreen).frame(width: 6, height: 6)
                            Text("Activos ahora en \(destination?.name ?? "tu destino")")
                                .font(BT.caption1)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }

                    Spacer()
                }
                .padding(Spacing.md)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .padding(.top, Spacing.lg)

                // Body text
                Text("En el momento en que pongas un pie aquí, tócalo.\nAlguien ya está pendiente de tu llegada.")
                    .font(BT.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.md)

                // Steps — glass row
                VStack(alignment: .leading, spacing: 0) {
                    glassStep(icon: "bell.fill",    text: "Un buddy sabrá que llegaste")
                    Divider().background(.white.opacity(0.15))
                    glassStep(icon: "message.fill", text: "Te escribe en minutos")
                    Divider().background(.white.opacity(0.15))
                    glassStep(icon: "heart.fill",   text: "Das tu primer paso con compañía")
                }
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .padding(.top, Spacing.lg)

                // CTA
                Button {
                    Haptic.medium()
                    activateJourney()
                } label: {
                    HStack(spacing: 8) {
                        if isActivating {
                            ProgressView().tint(.black).scaleEffect(0.8)
                        } else {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 16))
                        }
                        Text("Ya llegué")
                            .font(BT.footnoteBold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(.white)
                    .foregroundStyle(.black)
                    .clipShape(Capsule())
                }
                .disabled(isActivating)
                .padding(.top, Spacing.lg)
                .padding(.bottom, 90)
            }
            .padding(.horizontal, Spacing.edge)
        }
        .navigationBarBackButtonHidden(false)
        .toolbarBackground(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: – Helpers

    private var heroFallback: some View {
        LinearGradient(colors: [Color.tealDeep, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var arrivalLabel: String {
        guard let date = journey.arrivalAt else { return "Hoy" }
        if Calendar.current.isDateInToday(date) { return "Hoy · \(shortDate(date))" }
        if Calendar.current.isDateInTomorrow(date) { return "Mañana · \(shortDate(date))" }
        return shortDate(date)
    }

    private func shortDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_PE")
        df.dateFormat = "d MMM"
        return df.string(from: date)
    }

    @ViewBuilder
    private func glassChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(BT.caption1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func glassStep(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24)
            Text(text)
                .font(BT.callout)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 13)
    }

    private func activateJourney() {
        isActivating = true
        let journeyId = journey.id
        let destId    = journey.destination?.id
        Task {
            try? await APIClient.shared.updateJourneyStatus(journeyId: journeyId, status: "active")

            await MainActor.run {
                isActivating = false
                // journeyActivated: TripsView limpia su stack, InicioView carga datos y cambia tab cuando esté listo
                NotificationCenter.default.post(name: .journeyActivated, object: nil)
            }

            // Ruta en background — la navegación no espera
            if let destId {
                await routeStore.fetchDestinationFromAPI(id: destId)
            } else {
                await routeStore.fetchDestinationFromAPI()
            }
        }
    }
}
