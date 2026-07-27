# 003 Thermal Process Monitor

Thermal process monitor specification.

## Purpose

Detect sustained thermal pressure.
Show the processes that are the most likely heat sources.
Ask the user to close, restart, or ignore one safe app candidate.

## Scope

- In scope:
  - Battery temperature when macOS exposes it.
  - CPU thermal throttling.
  - System load.
  - User-owned process CPU usage.
  - Safe third-party app bundle detection.
  - User-selected close, restart, or ignore actions.
  - Confirmation and prompt cooldown limits.
  - Status and event history.
- Out of scope:
  - Exact CPU or GPU die temperature.
  - Exact per-process power or GPU attribution.
  - Privileged sampling with `sudo` or `powermetrics`.
  - Automatic termination without a user choice.
  - Termination of Apple apps, system services, or processes without an app bundle.

## Persistence

- `ThermalMonitor`
  - `observations`: Consecutive observations for each process identity.
  - `prompts`: The last prompt time for each process identity.
  - `ignored`: The last ignore time for each process identity.
- `Event`
  - Use the existing DETS event store.
  - Store process identity, display name, PID, CPU usage, and app bundle path.
  - Do not store command-line arguments.

## Behavior

1. Read CPU thermal throttling, system load, and battery temperature.
2. Treat thermal throttling, battery temperature of at least 40 degrees Celsius, or high load as thermal pressure.
3. Read user-owned processes and sort them by CPU usage.
4. Keep processes that use at least 20 percent CPU.
5. Mark a process as actionable only when it belongs to a third-party app bundle.
6. Never offer an action for Apple apps, system paths, or processes without a safe app bundle.
7. Confirm the same leading actionable process in two consecutive check rounds.
8. Show at most one action dialog per check round.
9. Show the leading process and up to four other high-CPU suspects.
10. Ask the user to Close, Restart, or Ignore the leading app.
11. Apply a one-hour prompt cooldown after any choice.
12. Close only the selected process.
13. Restart by closing the selected process and opening the same app bundle.
14. Log detection, choice, success, and failure.
15. Clear pending observations when thermal pressure ends.

CPU usage is correlation evidence.
It is not proof of exact heat contribution.

## BDD Scenarios

### BDD-01 Confirm sustained heat

Given:
- Thermal pressure is active.
- One third-party app uses at least 20 percent CPU.

When:
- The same app leads two consecutive check rounds.

Then:
- canaryd asks the user to Close, Restart, or Ignore the app.

### BDD-02 Clear transient heat

Given:
- One hot observation exists.

When:
- Thermal pressure ends.

Then:
- canaryd clears the pending observation.

### BDD-03 Protect system processes

Given:
- A system process is the leading CPU user.

When:
- canaryd evaluates the process list.

Then:
- canaryd reports the process as a suspect.
- canaryd does not offer a close or restart action for it.

## Cross-Spec Links

- [001 Unresponsive App Recovery](./001-unresponsive-app-recovery.md)
