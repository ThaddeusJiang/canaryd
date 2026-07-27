# 003 Thermal Process Monitor

Thermal process monitor specification.

## Purpose

Detect sustained thermal pressure.
Show the processes that are the most likely heat sources.
Ask the user to close, restart, or ignore one safe app candidate.

## Scope

- In scope:
  - Average CPU and GPU sensor temperature through `macmon 0.8.0`.
  - Battery temperature when macOS exposes it.
  - CPU thermal throttling.
  - System load.
  - User-owned process CPU usage.
  - Safe third-party app bundle detection.
  - User-selected close, restart, or ignore actions.
  - Confirmation and prompt cooldown limits.
  - Status and event history.
- Out of scope:
  - Per-core temperature.
  - Exact per-process temperature attribution.
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

1. Require `macmon 0.8.0` for CPU and GPU sensor temperature.
2. Read three temperature samples over a short window.
3. Keep the highest average CPU and GPU sensor temperature in that window.
4. Read CPU thermal throttling, system load, and battery temperature.
5. Treat CPU or GPU temperature of at least 70 degrees Celsius, thermal throttling, or high load as thermal pressure.
6. Keep battery temperature as a separate metric.
7. Do not use battery temperature as CPU or GPU temperature.
8. Report temperature as unavailable when `macmon` is missing, incompatible, or returns invalid output.
9. Read user-owned processes and sort them by CPU usage.
10. Keep processes that use at least 20 percent CPU.
11. Mark a process as actionable only when it belongs to a third-party app bundle.
12. Never offer an action for Apple apps, system paths, or processes without a safe app bundle.
13. Confirm the same leading actionable process in two consecutive check rounds.
14. Show at most one action dialog per check round.
15. Show the CPU and GPU temperature, the leading process, and up to four other high-CPU suspects.
16. Ask the user to Close, Restart, or Ignore the leading app.
17. Apply a one-hour prompt cooldown after any choice.
18. Close only the selected process.
19. Restart by closing the selected process and opening the same app bundle.
20. Log detection, choice, success, and failure.
21. Clear pending observations when thermal pressure ends.

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
