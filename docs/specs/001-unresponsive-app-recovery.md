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
  - Automatic recovery for allowlisted system services.
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
- A confirmed allowlisted service restarts without prompting the user.
- An app that stays unresponsive during cooldown becomes blocked.
- A responsive or stopped app clears its blocked state.

### Constraints and Indexes

- An app needs two consecutive observations before a restart.
- An app can restart at most once per hour.
- Restart timestamps older than 24 hours can be removed.
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
5. Include `com.apple.TextInputUI.xpc.CursorUIViewService` as an explicit automatic service only when its activation policy and system XPC path also match.
6. Confirm an unresponsive process in two consecutive check rounds.
7. Restart a confirmed third-party app or allowlisted service automatically.
8. Do not notify the user after a successful automatic restart.
9. Send `SIGTERM` to stop the current `CursorUIViewService` instance.
10. Send `SIGKILL` if the service does not stop within the grace period.
11. Wait up to five seconds for launchd or an XPC client to start a new service PID.
12. Report and notify on restart failure when a new PID does not appear in that period.
13. Send `SIGTERM` to a confirmed third-party app.
14. Send `SIGKILL` only when the same app process does not stop within the grace period.
15. Wait for the old app PID to stop.
16. Open the same third-party app bundle in the background.
17. Notify once when an app is confirmed unresponsive again during restart cooldown.
18. Log detection, restart, restart failure, and blocked events.

## BDD Scenarios

### BDD-01 Restart CursorUIViewService without prompting

Given:
- `CursorUIViewService` matches the allowlisted identity and system XPC path.
- It is unresponsive in two consecutive check rounds.

When:
- canaryd evaluates the second observation.

Then:
- canaryd automatically stops the old PID.
- canaryd waits for a replacement PID.
- a successful restart does not send a notification.

Test Plan:
- Lowest useful level: unit tests for service allowlisting and monitor actions.
- First failing test: the second service observation returns an automatic restart action.
- Follow-up test: interactive app recovery references are absent from production code.

Acceptance Evidence:
- `Canaryd.Apps.UnresponsiveTest` allowlist and recovery-mode test.
- `Canaryd.UnresponsiveMonitorTest` automatic service restart test.

Automatic termination can discard unsaved data. Exact service identity checks, confirmation, and cooldown limits reduce this risk.

## Search

- Not applicable.

## AI

- Not applicable.

## Cross-Spec Links

- [002 CleanClip Health Probe](./002-cleanclip-health-probe.md)
- [004 Notification Identity](./004-notification-identity.md)

## Open Questions

- None.

## Acceptance Record

| Scenario | Status | Evidence | Notes |
| --- | --- | --- | --- |
| BDD-01 | passed | `Canaryd.Apps.UnresponsiveTest`, `Canaryd.UnresponsiveMonitorTest`, full test suite, local production-path restart simulation | The isolated simulation replaced PID 21447 with PID 21449 and returned `:ok` without touching the real service. |
