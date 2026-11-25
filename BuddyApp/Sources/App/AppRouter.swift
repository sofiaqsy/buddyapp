import SwiftUI

// MARK: – AppRouter
// Single source of truth for cross-tab navigation.
// Used as @EnvironmentObject in SwiftUI views, and via .shared from
// non-SwiftUI callers (NotificationRouter, AppDelegate).

final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var selectedTab: AppTab = .inicio

    /// "Mis trips" vive en Yo (19 Nov 2026): abre Yo y empuja Mis trips.
    @Published var pendingMyTrips = false
    func openMyTrips() {
        pendingMyTrips = true
        switchTo(.yo)
    }

    /// Conversación con un negocio abierta desde una notificación.
    @Published var pendingBizChat: BusinessChatTarget? = nil

    /// Abre la conversación de la notificación. Si es una pregunta a uno de mis
    /// negocios, activa ese negocio primero para responder como él.
    func openBusinessChat(conversationId: String, farmId: String?) {
        Task { @MainActor in
            if let farmId, AccountStore.shared.businesses.contains(where: { $0.id == farmId }) {
                AccountStore.shared.activeBusinessId = farmId
            }
            switchTo(.conexiones)
            let biz = farmId == nil ? nil : AccountStore.shared.active
            let list = (try? await APIClient.shared.businessConversations(farmId: biz?.id)) ?? []
            let c = list.first { $0.id == conversationId }
            let title = (biz == nil ? c?.businessName : c?.travelerName) ?? (biz == nil ? "Negocio" : "Visitante")
            pendingBizChat = BusinessChatTarget(conversationId: conversationId, title: title)
        }
    }

    func switchTo(_ tab: AppTab) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                self.selectedTab = tab
            }
        }
    }

    func openPlace(lat: Double, lng: Double, name: String) {
        PlaceDeepLink.shared.pending = .init(lat: lat, lng: lng, name: name)
        switchTo(.inicio)
    }

    func openBuddyProfile() {
        switchTo(.yo)
    }
}
