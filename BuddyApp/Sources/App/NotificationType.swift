import Foundation

// ─── NotificationType ─────────────────────────────────────────────────────────
// Shared definition of every push notification type Buddy sends.
// Must stay in sync with NotificationService.js TYPES on the backend.
//
// Adding a new type:
//   1. Add a case here.
//   2. Add the rawValue string to NotificationService.TYPES (backend).
//   3. Add a routing case in NotificationRouter.route(_:).
// ─────────────────────────────────────────────────────────────────────────────

enum NotificationType: String {
    /// Buddy receives a new help request from the matching engine.
    /// Priority: High — buddy has 60 s to respond.
    case helpOffer          = "help_offer"

    /// Traveler's request was accepted by a buddy.
    /// Priority: High — traveler is waiting; push is fallback when SSE is down.
    case buddyAccepted      = "buddy_accepted"

    /// New chat message for the other participant.
    /// Priority: Medium — iOS suppresses if the chat is already open.
    case newMessage         = "new_message"

    /// Buddy profile was approved by the team.
    /// Priority: Low — one-time milestone.
    case buddyApproved      = "buddy_approved"

    /// Buddy completed their very first match.
    /// Priority: Low — one-time celebratory milestone.
    case firstHelpCompleted = "first_help_completed"

    init?(userInfo: [AnyHashable: Any]) {
        guard let raw = userInfo["type"] as? String else { return nil }
        self.init(rawValue: raw)
    }
}
