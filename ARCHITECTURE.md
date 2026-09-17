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

## Release test (must pass before release candidate)

1. Existing user: sign in, check trips, profile and photos, kill the app, reopen. Everything must still be there.
2. Reinstall: delete the app, install again, open it. No new guest may be created. If the refresh fails, the app asks you to sign in. Signing in with the same Google or Apple account must bring back the same account id, trips, profile and data.
3. Guest: start as a guest, use the app, sign out or reinstall. Guest behavior must still work, and guest logic must never affect verified users.
