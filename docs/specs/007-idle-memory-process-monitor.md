# 007 Idle Memory Process Monitor

Idle high-memory process recovery specification.

## Purpose

Recover memory from inactive third-party applications after sustained user and
application inactivity without terminating system processes or the application
that the user most recently used.

## Scope

- In scope:
  - Applications owned by the current macOS user.
  - Aggregate RSS and CPU usage for a top-level third-party app bundle.
  - Sustained user inactivity and low application CPU use.
  - Graceful automatic application termination.
  - Confirmation, cooldown, local event history, and notifications.
- Out of scope:
  - Apple applications, system processes, and command-line daemons.
  - Apps outside `/Applications` and the current user's `Applications` folder.
  - Nested helper app bundles as independent close targets.
  - The frontmost application.
  - Forced termination with `SIGKILL`.
  - Exact attribution of shared memory to one application.

## Persistence

### Entities

- `IdleMemoryMonitor`
  - `observations`: A map keyed by app identity with the latest app snapshot and
    consecutive observation count.
  - `closes`: The last automatic close time for each app identity.
- `AppIdentity`
  - Use the bundle identifier for a registered application.
  - Fall back to the absolute top-level app bundle path only when necessary.
- `Event`
  - Use the existing DETS event store.
  - Store app identity, display name, PID, aggregate RSS, aggregate CPU use,
    bundle identifier, and bundle path.
  - Do not store command-line arguments.

### Lifecycle

- An eligible sample creates or advances a pending observation.
- A sample below the memory threshold clears its pending observation.
- CPU activity, user activity, an active app, a changed PID, or an unavailable
  process scan breaks the consecutive sequence.
- Three consecutive observations confirm an idle high-memory application.
- A confirmed application receives one graceful termination request.
- A close timestamp prevents another close of the same app during cooldown.
- Close timestamps older than 24 hours can be removed.

### Constraints and Indexes

- Aggregate RSS must be at least 1,024 MB.
- Aggregate CPU use must be at most 1 percent.
- The user must be inactive for at least 30 minutes.
- Confirmation requires three consecutive five-minute full check rounds.
- The same app can be closed at most once per hour.
- A PID change resets confirmation for that app identity.
- The monitor must not create atoms from process or application metadata.

### Retention and Privacy

- Data stays in the existing local Canaryd DETS files.
- Existing event retention behavior applies.
- Command-line arguments and document content are not persisted.

## Relationships

- `Canaryd.Checker` runs this monitor during the five-minute full health check.
- `Canaryd.System.idle_duration/0` supplies user inactivity.
- `Canaryd.MemoryProcesses` registers apps and aggregates their process trees.
- Thermal and unresponsive-app monitors keep their existing policies.

## Behavior

1. Skip process collection while the user has been inactive for less than 30
   minutes and clear incomplete observations.
2. Read registered macOS applications through `NSWorkspace`.
3. Read PID, UID, CPU, RSS, and executable paths through `ps` without `sudo`.
4. Keep processes owned by the current user.
5. Aggregate processes under their top-level app bundle.
6. Consider only top-level third-party bundles in `/Applications` or the
   current user's `Applications` directory.
7. Protect Apple apps, system paths, nested helpers, unregistered processes,
   and the active application.
8. Treat aggregate RSS of at least 1,024 MB and aggregate CPU of at most 1
   percent as one eligible observation.
9. Require three consecutive eligible observations for the same app identity
   and PID.
10. Revalidate the PID's bundle identifier and bundle path immediately before
    acting so PID reuse cannot close a different app.
11. Request graceful termination through `NSRunningApplication`.
12. Wait briefly for the app to stop and report failure if it refuses or stays
    alive.
13. Never escalate an idle-memory close to `SIGKILL`.
14. Notify the user after a successful close and after a close failure.
15. Log detection, successful close, and close failure events.
16. Expose pending apps through `canaryd status` and events through
    `canaryd history memory`.

Automatic termination can still interrupt background work or expose an app's
unsaved-changes prompt. User inactivity, app inactivity, active-app protection,
confirmation, graceful termination, and cooldown reduce this risk.

## BDD Scenarios

### BDD-01 Close a sustained idle high-memory app

Given:
- The user has been inactive for at least 30 minutes.
- A non-active third-party app uses at least 1,024 MB RSS.
- The app uses at most 1 percent aggregate CPU.

When:
- The same app and PID meet those conditions for three consecutive full checks.

Then:
- Canaryd requests graceful application termination.
- Canaryd does not send `SIGKILL`.
- Canaryd logs the close and notifies the user.

### BDD-02 Reset transient observations

Given:
- An app has one or two eligible observations.

When:
- The user becomes active, the app uses more CPU, its RSS falls, or its PID
  changes.

Then:
- Canaryd does not close the app.
- A later eligible sample starts a new confirmation sequence.

### BDD-03 Protect unsafe targets

Given:
- A high-memory process belongs to Apple, a system path, an unregistered
  command, a nested helper bundle, another user, or the active application.

When:
- Canaryd scans processes.

Then:
- Canaryd does not mark that target actionable.
- Canaryd does not request termination.

## Search

- Not applicable.

## AI

- Not applicable.

## Cross-Spec Links

- [001 Unresponsive App Recovery](./001-unresponsive-app-recovery.md)
- [003 Thermal Process Monitor](./003-thermal-process-monitor.md)
- [005 Time Unit Convention](./005-time-unit-convention.md)
- [008 Idle Simulator Shutdown](./008-idle-simulator-shutdown.md)

## Open Questions

- None.
