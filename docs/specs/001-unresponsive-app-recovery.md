# 001 Unresponsive App Recovery

Unresponsive app recovery specification.

## Purpose

Detect GUI processes that macOS marks as not responding.
Recover a confirmed unresponsive process with the correct safety policy.

## Scope

- In scope:
  - User-visible macOS apps in the current login session.
  - Explicitly allowlisted system GUI services.
  - The same unresponsive state that macOS shows in Force Quit.
  - Automatic restart with confirmation and cooldown limits.
  - Notification and user-selected recovery for allowlisted system services.
  - Status and event history.
- Out of scope:
  - Background daemons and helper processes that are not allowlisted.
  - Apple system apps and services that are not allowlisted.
  - Diagnosis of the cause of an app hang.
  - Recovery of unsaved app data.

## Persistence

### Entities

- `UnresponsiveAppMonitor`
  - `observations`: A map keyed by app identity.
  - `restarts`: The last automatic restart time for each app identity.
  - `prompts`: The last interactive recovery prompt time for each app identity.
  - `blocked`: App identities that already caused a user notification.
- `AppIdentity`
  - Use the bundle identifier when it is available.
  - Otherwise, use the absolute app bundle path.
- `Event`
  - Use the existing DETS event store.
  - Store the app identity, display name, PID, and bundle path in event details.

### Lifecycle

- The first unresponsive observation creates a pending observation.
- A responsive or stopped app clears its pending observation.
- Two consecutive unresponsive observations confirm a hang.
- A confirmed hang starts an automatic restart when the cooldown permits it.
- A confirmed allowlisted service sends a notification and asks the user to ignore, close, or restart it.
- An app that stays unresponsive during cooldown becomes blocked.
- A responsive or stopped app clears its blocked state.

### Constraints and Indexes

- An app needs two consecutive observations before a restart.
- An app can restart at most once per hour.
- An allowlisted service can prompt at most once per hour.
- Restart timestamps older than 24 hours can be removed.
- Prompt timestamps older than 24 hours can be removed.
- The monitor must not create atoms from app names or bundle identifiers.

### Retention and Privacy

- Data stays in the existing local canaryd DETS files.
- The monitor does not store document content or command-line arguments.
- Existing event retention behavior applies.

## Relationships

- `Canaryd.Checker` runs the monitor during every check round.
- Idle-user checks still scan the macOS responsiveness state.
- The CleanClip functional probe keeps its existing behavior.

## Behavior

1. Query the WindowServer responsiveness state for running GUI apps.
2. Clear pending observations and stop without restart actions when the macOS interface is unavailable.
3. Keep third-party apps with a regular activation policy.
4. Exclude Apple bundle identifiers and app bundles under system paths by default.
5. Include `com.apple.TextInputUI.xpc.CursorUIViewService` as an explicit interactive service.
6. Confirm an unresponsive process in two consecutive check rounds.
7. Restart a confirmed third-party app automatically.
8. Send a Notification Center notification for a confirmed interactive service.
9. Show an action dialog with Ignore, Close, and Restart.
10. Close the action dialog after 120 seconds and treat timeout as Ignore.
11. Send `SIGTERM` to close the current `CursorUIViewService` instance.
12. Send `SIGKILL` if the service does not stop within the grace period.
13. For Restart, wait up to five seconds for launchd or an XPC client to start a new PID.
14. Report restart failure when a new PID does not appear in that period.
15. Send `SIGTERM` to a confirmed third-party app.
16. Send `SIGKILL` only when the same app process does not stop within the grace period.
17. Wait for the old app PID to stop.
18. Open the same third-party app bundle in the background.
19. Log detection, user choice, restart, restart failure, and blocked events.

Automatic termination can discard unsaved data. Confirmation and cooldown limits reduce this risk.

## Search

- Not applicable.

## AI

- Not applicable.

## Cross-Spec Links

- None.

## Open Questions

- None.
