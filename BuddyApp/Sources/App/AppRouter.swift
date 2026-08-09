import SwiftUI

// MARK: – AppRouter
// Single source of truth for cross-tab navigation.
// Used as @EnvironmentObject in SwiftUI views, and via .shared from
// non-SwiftUI callers (NotificationRouter, AppDelegate).

final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var selectedTab: AppTab = .inicio

    func switchTo(_ tab: AppTab) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                self.selectedTab = tab
            }
        }
    }

    func openPlace(lat: Double, lng: Double, name: String,
                   spotId: String? = nil, destinationId: String? = nil) {
        PlaceDeepLink.shared.pending = .init(lat: lat, lng: lng, name: name,
                                             spotId: spotId, destinationId: destinationId)
        switchTo(.inicio)
    }

    func openBuddyProfile() {
        switchTo(.yo)
    }
}
