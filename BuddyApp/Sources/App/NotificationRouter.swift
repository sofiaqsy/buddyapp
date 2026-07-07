import Foundation

// ─── NotificationRouter ───────────────────────────────────────────────────────
// Single entry point for all push notification routing.
// AppDelegate calls route(_:) on tap and shouldSuppress(_:) before showing a
// foreground banner. No navigation logic lives outside this file.
//
// Routing table
// ─────────────────────────────────────────────────────────────────────────────
// helpOffer          → switchToTab(.conexiones)  [offers reload via .helpOfferReceived]
// buddyAccepted      → openChatForMatch(id) + switchToTab(.conexiones)
// newMessage         → openChatForMatch(id) + switchToTab(.conexiones)
// buddyApproved      → openBuddyProfile  + switchToTab(.yo)
// firstHelpCompleted → switchToTab(.conexiones)
// ─────────────────────────────────────────────────────────────────────────────

enum NotificationRouter {

    // MARK: – Tap routing (background → foreground / terminated → open)

    static func route(_ userInfo: [AnyHashable: Any]) {
        guard let type = NotificationType(userInfo: userInfo) else { return }

        switch type {

        case .helpOffer:
            post(.helpOfferReceived, userInfo: userInfo)
            switchTab(.conexiones)

        case .buddyAccepted, .newMessage:
            if let matchId = userInfo["match_id"] as? String {
                post(.openChatForMatch, userInfo: ["match_id": matchId])
            }
            switchTab(.conexiones)

        case .buddyApproved:
            AppRouter.shared.openBuddyProfile()

        case .firstHelpCompleted:
            switchTab(.conexiones)
        }
    }

    // MARK: – Foreground suppression

    /// Returns true when the push banner should be silenced because the user
    /// is already looking at the relevant screen via realtime (SSE).
    static func shouldSuppress(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let type = NotificationType(userInfo: userInfo) else { return false }

        switch type {
        case .newMessage:
            // Suppress when the recipient already has that chat open
            guard let matchId = userInfo["match_id"] as? String else { return false }
            return ChatPresenceTracker.shared.activeChatMatchId == matchId

        case .buddyAccepted:
            // SSE in ContactarBuddyView handles this in real time; suppress the banner
            // only if we can confirm SSE delivered it (tracked via ChatPresenceTracker)
            // For now: always show — SSE may be down in background.
            return false

        default:
            return false
        }
    }

    // MARK: – Helpers

    private static func switchTab(_ tab: AppTab) {
        AppRouter.shared.switchTo(tab)
    }

    private static func post(_ name: Notification.Name, userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }
}
