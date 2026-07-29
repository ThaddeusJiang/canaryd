# 002 CleanClip Health Probe

CleanClip functional health probe specification.

## Purpose

Verify that CleanClip records new clipboard items.
Do not change the clipboard content that the user expects to paste.

## Scope

- In scope:
  - A synthetic item on the general macOS pasteboard.
  - A complete snapshot of the existing pasteboard items and data types.
  - Conditional restoration after the probe wait period.
  - Detection through the CleanClip history directory modification time.
- Out of scope:
  - Recovery of clipboard content that another process already removed.
  - Diagnosis of other pasteboard writers.
  - Changes to CleanClip settings or history.

## Persistence

The probe does not add new canaryd state.
CleanClip can retain the synthetic item in its own history.
The existing canaryd state and event retention rules still apply.

## Relationships

- `Canaryd.Checker` runs the probe during each active check round.
- CleanClip records the synthetic item.
- The general macOS pasteboard supplies the transaction boundary.

## Behavior

1. Save all current pasteboard items and their data types.
2. Clear the pasteboard and write one unique text marker.
3. Record the pasteboard change count after the marker write.
4. Wait for CleanClip to record the marker.
5. Restore the saved items only when the change count is unchanged.
6. Keep newer content when a user or another process changes the pasteboard during the wait.
7. Report a probe failure when the pasteboard transaction cannot run.
8. Check the CleanClip history directory after the transaction completes.

## BDD Scenarios

### BDD-01 Restore unchanged clipboard content

Goal:
- Keep the content that was present before the probe.

Given:
- The pasteboard contains one or more items.
- No process changes the pasteboard during the probe wait period.

When:
- canaryd runs the CleanClip functional probe.

Then:
- CleanClip can observe the synthetic marker.
- canaryd restores every saved pasteboard item and data type.

Test Plan:
- Lowest useful level: JXA integration test with a named pasteboard.
- First failing test: the probe transaction restores text on a named pasteboard.
- Follow-up tests: preserve multiple data types.

Acceptance Evidence:
- Focused ExUnit tests.
- A named pasteboard transaction run.

### BDD-02 Keep newer clipboard content

Goal:
- Do not replace content that arrives after the probe starts.

Given:
- canaryd wrote the synthetic marker.

When:
- another writer changes the pasteboard during the probe wait period.

Then:
- canaryd does not restore the older snapshot.
- The newer pasteboard content stays available.

Test Plan:
- Lowest useful level: JXA integration test with a named pasteboard.
- First failing test: a simulated concurrent write changes the change count and blocks restoration.
- Follow-up tests: none.

Acceptance Evidence:
- Focused ExUnit test.

### BDD-03 Report a transaction failure

Goal:
- Keep the health check process alive when the pasteboard transaction fails.

Given:
- The system command returns a non-zero status.

When:
- canaryd runs the CleanClip functional probe.

Then:
- The probe returns a failure result.
- The checker can apply its existing recovery policy.

Test Plan:
- Lowest useful level: unit test with a command runner.
- First failing test: a non-zero command status returns a transaction failure.
- Follow-up tests: none.

Acceptance Evidence:
- Focused ExUnit test.

## Search

- Not applicable.

## AI

- Not applicable.

## Cross-Spec Links

- [001 Unresponsive App Recovery](./001-unresponsive-app-recovery.md)
- [004 Notification Identity](./004-notification-identity.md)

## Open Questions

- None.

## Acceptance Record

| Scenario | Status | Evidence | Notes |
| --- | --- | --- | --- |
| BDD-01 | passed | `restores every saved type when the probe marker is unchanged`; live type and text hash comparison | Named and general pasteboards verified |
| BDD-02 | passed | `keeps newer content when another writer changes the pasteboard` | Named pasteboard verified |
| BDD-03 | passed | `returns a failure when the pasteboard command fails` | Command runner verified |
