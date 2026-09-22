# BuddyApp architecture notes

## Session rule: authentication failure is not account creation

A token that cannot be refreshed must never turn a verified account into a new guest account. When that happened after a reinstall, the user saw an empty profile and believed their trips were gone.

```
App launch
   |
   +-- No stored session
   |       +-- Create / enter guest flow
   |
   +-- Stored session (Keychain: traveler id + status)
           |
           +-- Guest
           |     +-- refresh guest session
           |           +-- refresh fails -> clear session, new guest is allowed
           |
           +-- Verified
                 |
                 +-- refresh succeeds -> continue
                 |
                 +-- refresh fails
                        +-- keep id + status, mark needsReauth
                        +-- ask the user to sign in again ("Tu sesion expiro")
                        +-- NEVER create a guest account
```

## Where it lives (iOS)

- `TravelerService`
  - The Keychain stores both the traveler id and its status (`guest` or `verified`). The status used to be lost, so every restore came back as `guest`.
  - `expireSession()` handles a token that could not be refreshed. A guest is cleared completely. A verified account keeps its id and status and is marked `needsReauth`.
  - `clearSession()` is only for an intentional sign-out. It wipes everything, and after it a guest may be created.
  - `ensureSession()` and `createGuestSession()` refuse to create a guest while `needsReauth` is set or the Keychain holds a verified status.
- `APIClient.sharedRefresh` calls `expireSession()` when every refresh path fails.
- `AuthState.sessionNeedsReauth` presents `IdentitySheet(purpose: .reauth)` from `ContentView`. A successful sign-in calls `hydrate`, which clears `needsReauth`.

## Home feed: three layers, and one hard constraint

The Home feed is decided in `FeedRanking.secuencia` and only *displayed* by the
vertical pager. The pager never decides what comes next; the ranking layer never
knows about scrolling. Keep that split.

**The pager navigates the ranked feed; it does not build, rank, or reshape the
feed.** It is the three-card drag pager in `ContactarBuddyView.exploreCarousel`
(one drag = exactly one recommendation, cyclic by modulo arithmetic, no scroll
window). The native `ScrollView` paging it replaced caused three separate bugs
from the same source (a lazy 121-page window has no stable extent), so don't
bring it back. Startup work (the cached spots, when the network re-ranks) lives
upstream of the pager and must never require changing it.

```
LAYER 1 — LOCAL CONTEXT     the closest 3 distinct places, one photo each,
                            in distance order.            HARD CONSTRAINT
        ↓
LAYER 2 — LOCAL EXPLORATION other nearby places and photos:
                            diversity, recency, recently shown.
        ↓
LAYER 3 — DISCOVERY         farther places, remaining photos.
```

Layer 1 answers "what is around me?" before the feed becomes "what else can I
discover?". It is a product rule, not a scoring preference: no weighted score
may let a farther place open the feed.

Future signals — popularity, freshness, "recommended by someone you know",
personalization, seasonality — may reorder **inside layers 2 and 3**. None of
them may touch layer 1, and none may drop a photo: every photo stays reachable
exactly once per cycle.

The formal contract (invariants I1–I5, including the two cases where I5 is
mathematically impossible to satisfy) is written at the top of
`BuddyApp/Sources/Services/FeedRanking.swift`. `Tools/main.swift` pins it with
deterministic cases and runs without Xcode or a simulator:

```
swiftc -O BuddyApp/Sources/Services/FeedRanking.swift Tools/main.swift -o /tmp/feedtests && /tmp/feedtests
```

Run it before changing anything in the feed. If a change needs an invariant to
move, change the spec first, deliberately — not as a side effect.

## Release test (must pass before release candidate)

1. Existing user: sign in, check trips, profile and photos, kill the app, reopen. Everything must still be there.
2. Reinstall: delete the app, install again, open it. No new guest may be created. If the refresh fails, the app asks you to sign in. Signing in with the same Google or Apple account must bring back the same account id, trips, profile and data.
3. Guest: start as a guest, use the app, sign out or reinstall. Guest behavior must still work, and guest logic must never affect verified users.
