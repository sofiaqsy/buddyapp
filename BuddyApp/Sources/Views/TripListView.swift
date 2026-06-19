import SwiftUI

// TripListView — kept for nav compatibility
// Redirects to TripDetailView when a route is ready

struct TripListView: View {
    @EnvironmentObject var routeStore: RouteStore

    var body: some View {
        NavigationStack {
            if routeStore.isReady {
                TripDetailView(route: routeStore.route)
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "map")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Color.inkMuted.opacity(0.4))
            Text("Sin destino activo")
                .font(BT.title3)
                .foregroundStyle(Color.ink)
            Text("Registra tu próximo destino\ndesde la pantalla de inicio.")
                .font(BT.callout)
                .foregroundStyle(Color.inkMuted)
                .multilineTextAlignment(.center)
        }
        .navigationTitle("Mi trip")
        .navigationBarTitleDisplayMode(.large)
        .background(Color.canvas)
    }
}
