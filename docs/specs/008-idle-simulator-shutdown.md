# 008 Idle Simulator Shutdown

Idle booted Simulator device shutdown specification.

## Purpose

Release CPU, memory, and graphics resources held by forgotten Apple Simulator
devices without interrupting recent interactive use or supported unattended
test runs.

## Scope

- In scope:
  - Booted devices in the current user's default CoreSimulator device set.
  - Simulator foreground activity, device age, a fixed inactivity window, and
    test automation protection.
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
  - `last_foreground_at`: The latest full-check time when Simulator was the
    frontmost application, or `nil` until one is observed.
- `SimulatorDevice`
  - `udid`: The canonical uppercase CoreSimulator device identifier.
  - `name`: The user-visible device name.
  - `runtime`: The runtime heading reported by `simctl`.
  - `state`: `booted` for devices returned by the scanner.
  - `last_used_at`: The CoreSimulator `lastUsedAt` timestamp, or unavailable.
- `Event`
  - Use the existing DETS event store with target `simulators`.
  - Store UDID, name, runtime, state, and `last_used_at`.
  - Skipped and failed actions store a bounded reason value.

### Lifecycle

- A booted device becomes actionable when its latest known activity is at
  least 15 minutes old.
- Simulator foreground activity records a new inactivity baseline. Supported
  test automation blocks shutdown while it is active.
- The first full check after the fixed inactivity window produces one
  exact-device shutdown action.
- A successful shutdown removes the device from future scans.
- A failed or skipped action can be retried on a later safe check.

### Constraints and Indexes

- The later of device `lastUsedAt` and `last_foreground_at` must be at least
  15 minutes old.
- Full checks run every five minutes, so shutdown normally occurs 15–20 minutes
  after the latest known activity without increasing the daemon's wake rate.
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
- `Canaryd.Simulators` reads the foreground application and CoreSimulator state,
  detects supported automation, revalidates device identity, and performs
  shutdown.
- Thermal, idle-memory, unresponsive-app, and CleanClip policies remain
  independent.

## Behavior

1. List booted devices with `xcrun simctl list devices booted` on every full
   check, even while the Mac is in use.
2. Read the frontmost macOS application. If it is Simulator, record the current
   time as the inactivity baseline.
3. Read each device's CoreSimulator `lastUsedAt` timestamp. Treat it as a
   device-age guard, not as proof of per-device input activity while booted.
4. Inspect current-user process names without storing arguments.
5. If `xcodebuild` or `xctest` is active, do not shut down any device.
   Zombie processes do not count as active automation.
6. Keep only booted devices whose latest known activity is at least 15 minutes
   old. Latest activity is the later of device `lastUsedAt` and
   `last_foreground_at`.
7. Immediately before acting, recheck that Simulator is not in the foreground
   and that supported test automation is absent. Persist any foreground activity
   observed during this recheck as a new inactivity baseline. Recheck the latest
   baseline before each queued device action, including later actions in the
   same round.
8. Re-list booted devices and require the exact UDID and unchanged
   `lastUsedAt` value.
9. Run `xcrun simctl shutdown <UDID>` for each confirmed device.
10. Never run `simctl erase`, `simctl delete`, or `simctl shutdown all`.
11. Log every shutdown, skipped action, and failed action.
12. Batch successful or failed device names into at most one notification for
    each result class per check round.
13. Expose current status through `canaryd status` and events through
    `canaryd history simulators`.

## BDD Scenarios

### BDD-01 Shut down a sustained idle Simulator

Given:
- A Simulator device has not been used or brought to the foreground for at
  least 15 minutes.
- No current-user `xcodebuild` or `xctest` process is active.

When:
- Canaryd runs the first full check after the 15-minute inactivity window.

Then:
- Canaryd revalidates the safety signals and exact device identity.
- Canaryd runs `simctl shutdown` for that UDID.
- Canaryd preserves the device and all of its data.

### BDD-02 Start a new fixed inactivity window

Given:
- A booted Simulator becomes the foreground application or its `lastUsedAt`
  timestamp changes.

When:
- Canaryd observes later full checks.

Then:
- Canaryd does not shut down the device before the new activity baseline is
  15 minutes old.
- Canaryd may shut it down on the first safe full check after that threshold.

### BDD-03 Protect active automation and unverifiable devices

Given:
- A current-user `xcodebuild` or `xctest` process is active, or a device lacks a
  valid `lastUsedAt` value.

When:
- Canaryd runs a full check.

Then:
- Canaryd does not shut down that Simulator device.
- Canaryd does not erase, delete, or mutate device data.

### BDD-04 Keep scanning while the Mac is active

Given:
- The user is actively using another macOS application.
- Simulator is not the foreground application.

When:
- Canaryd runs a full check.

Then:
- Whole-Mac keyboard or pointer activity does not reset Simulator inactivity.
- Canaryd still evaluates the device and supported automation signals.

### BDD-05 Preserve activity observed during shutdown revalidation

Given:
- Idle devices have already been queued for shutdown.
- Simulator becomes the foreground application before an action executes.

When:
- The final foreground check detects this activity.

Then:
- Canaryd skips shutdown and saves a new activity baseline.
- The saved baseline protects later devices in the same round.
- Subsequent check processes reload it and wait a full 15 minutes before the
  next eligible shutdown.

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
