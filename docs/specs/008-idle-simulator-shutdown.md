# 008 Idle Simulator Shutdown

Idle booted Simulator device shutdown specification.

## Purpose

Release CPU, memory, and graphics resources held by forgotten Apple Simulator
devices without interrupting recent interactive use or supported unattended
test runs.

## Scope

- In scope:
  - Booted devices in the current user's default CoreSimulator device set.
  - User inactivity, device age, consecutive confirmation, and test automation
    protection.
  - Exact-device shutdown through `xcrun simctl`.
  - Local status, event history, and batched notifications.
- Out of scope:
  - Erasing, deleting, or resetting Simulator devices or their data.
  - Shutting down physical Apple devices.
  - Per-application activity measurement inside a simulated device.
  - Simulator device sets selected through a custom `--set` path.
  - Automatic shutdown while `xcodebuild` or `xctest` is running for the current
    user.

## Persistence

### Entities

- `IdleSimulatorMonitor`
  - `observations`: A map keyed by Simulator UDID with the latest device
    snapshot and consecutive observation count.
- `SimulatorDevice`
  - `udid`: The canonical uppercase CoreSimulator device identifier.
  - `name`: The user-visible device name.
  - `runtime`: The runtime heading reported by `simctl`.
  - `state`: `booted` for devices returned by the scanner.
  - `last_used_at`: The CoreSimulator `lastUsedAt` timestamp, or unavailable.
- `Event`
  - Use the existing DETS event store with target `simulators`.
  - Store UDID, name, runtime, state, and `last_used_at`.
  - Detection events also store the consecutive observation count.
  - Skipped and failed actions store a bounded reason value.

### Lifecycle

- A booted device old enough to qualify creates or advances an observation.
- User activity, supported test automation, a changed `lastUsedAt` timestamp,
  shutdown, a missing device, or an unavailable scan clears the incomplete
  sequence.
- Three consecutive observations produce one exact-device shutdown action.
- A successful shutdown removes the device from future scans.
- A failed or skipped action requires a new three-observation sequence before
  another attempt.

### Constraints and Indexes

- User inactivity must be at least 30 minutes.
- Device `lastUsedAt` age must be at least 30 minutes.
- Confirmation requires three consecutive five-minute full check rounds.
- Missing or invalid `lastUsedAt` data makes a device non-actionable.
- A current-user `xcodebuild` or `xctest` process blocks shutdown for every
  device in that round.
- Actions use one validated UDID and never use the `all` alias.
- The device must still be booted with the same `lastUsedAt` immediately before
  shutdown.
- The monitor must not create atoms from device or process metadata.

### Retention and Privacy

- Monitor state and events stay in the existing local Canaryd DETS files.
- Existing event retention behavior applies.
- Device data paths, process arguments, application data, and test output are
  not persisted.

## Relationships

- `Canaryd.Checker` runs the monitor during the five-minute full health check.
- `Canaryd.System.idle_duration/0` supplies whole-Mac keyboard and pointer
  inactivity.
- `Canaryd.Simulators` reads CoreSimulator state, detects supported automation,
  revalidates device identity, and performs shutdown.
- Thermal, idle-memory, unresponsive-app, and CleanClip policies remain
  independent.

## Behavior

1. While the user has been inactive for less than 30 minutes, skip Simulator
   collection and clear incomplete observations.
2. List booted devices with `xcrun simctl list devices booted`.
3. Read each device's CoreSimulator `lastUsedAt` timestamp. Treat it as a
   device-age guard, not as proof of per-device input activity while booted.
4. Inspect current-user process names without storing arguments.
5. If `xcodebuild` or `xctest` is active, clear incomplete observations and do
   not shut down any device.
6. Keep only booted devices whose `lastUsedAt` age is at least 30 minutes.
7. Require three consecutive eligible observations for the same UDID and
   `lastUsedAt` value.
8. Immediately before acting, recheck whole-Mac inactivity and supported test
   automation.
9. Re-list booted devices and require the exact UDID and unchanged
   `lastUsedAt` value.
10. Run `xcrun simctl shutdown <UDID>` for each confirmed device.
11. Never run `simctl erase`, `simctl delete`, or `simctl shutdown all`.
12. Log every detection, shutdown, skipped action, and failed action.
13. Batch successful or failed device names into at most one notification for
    each result class per check round.
14. Expose pending devices through `canaryd status` and events through
    `canaryd history simulators`.

## BDD Scenarios

### BDD-01 Shut down a sustained idle Simulator

Given:
- The user has been inactive for at least 30 minutes.
- A Simulator device has been booted or last used for at least 30 minutes.
- No current-user `xcodebuild` or `xctest` process is active.

When:
- The same UDID and `lastUsedAt` value remain eligible for three consecutive
  full checks.

Then:
- Canaryd revalidates the safety signals and exact device identity.
- Canaryd runs `simctl shutdown` for that UDID.
- Canaryd preserves the device and all of its data.

### BDD-02 Reset transient observations

Given:
- A booted Simulator has one or two eligible observations.

When:
- The user becomes active, test automation starts, the device timestamp
  changes, the device shuts down, or collection becomes unavailable.

Then:
- Canaryd clears the incomplete sequence.
- A later eligible sample starts again at one.

### BDD-03 Protect active automation and unverifiable devices

Given:
- A current-user `xcodebuild` or `xctest` process is active, or a device lacks a
  valid `lastUsedAt` value.

When:
- Canaryd runs a full check.

Then:
- Canaryd does not shut down that Simulator device.
- Canaryd does not erase, delete, or mutate device data.

## Search

- Not applicable.

## AI

- Not applicable.

## Cross-Spec Links

- [005 Time Unit Convention](./005-time-unit-convention.md)
- [007 Idle Memory Process Monitor](./007-idle-memory-process-monitor.md)

## Open Questions

- Expand the automation blocker list only when a new tool has a stable,
  low-false-positive process identity.
