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
  - `alerts`: The last warning notification time for each process identity.
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
7. Format available temperature values with the `°C` unit.
8. Omit battery temperature when it is unavailable.
9. Do not use battery temperature as CPU or GPU temperature.
10. Report temperature as unavailable when `macmon` is missing, incompatible, or returns invalid output.
11. Read user-owned processes and sort them by CPU usage.
12. Keep processes that use at least 20 percent CPU.
13. Mark a process as actionable only when it belongs to a third-party app bundle.
14. Never offer an action for Apple apps, system paths, or processes without a safe app bundle.
15. Send a notification on the first thermal-pressure observation.
16. Do not activate an app or show a foreground dialog.
17. Keep the warning in Notification Center until the user dismisses it.
18. Apply a 15-minute warning notification cooldown for each leading process.
19. Confirm the same leading actionable process in two consecutive check rounds.
20. Show at most one actionable notification per check round.
21. Show the CPU and GPU temperature, the leading process, and up to four other high-CPU suspects.
22. Show Close and Restart actions in the notification.
23. Treat dismiss or timeout as Ignore.
24. Apply a one-hour prompt cooldown after any choice.
25. Close only the selected process.
26. Restart by closing the selected process and opening the same app bundle.
27. Log warning delivery, choice, success, and failure.
28. Clear pending observations when thermal pressure ends.
29. Run a dedicated thermal check every minute.
30. Keep the full health check interval at five minutes.
31. Use the shared store lock to prevent concurrent check rounds.

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
- canaryd sends a notification after the first hot round.
- canaryd keeps the warning in Notification Center until the user dismisses it.
- canaryd shows Close and Restart in the notification after the second hot round.
- canaryd treats dismiss or timeout as Ignore.
- canaryd does not activate an app.

Test Plan:
- Lowest useful level: unit test for each notification command contract.
- First failing test: the helper does not remove an informational warning after delivery.
- Follow-up test: the actionable temperature notification returns the selected action.

Acceptance Evidence:
- `Canaryd.SystemThermalTest` temperature summary formatting tests.
- `Canaryd.NotifierTest` temperature notification tests.
- Swift helper compile check.

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

## Relationships

- `Canaryd.Setup` installs the one-minute thermal agent and the five-minute full-check agent.
- `Canaryd.Checker.run_thermal/0` runs only the system and thermal process checks.
- `Canaryd.Store` prevents two agents from changing monitor state at the same time.

## Acceptance Record

| Scenario | Status | Evidence | Notes |
| --- | --- | --- | --- |
| BDD-01 | passed | `Canaryd.SystemThermalTest`, `Canaryd.NotifierTest`, `Canaryd.NotificationHelperTest`, Swift type check, signed helper install, live persistent warning run | Available temperatures use `°C`. Unavailable battery temperature is omitted. The warning had no removal event after 35 seconds. The action notification returned Ignore after dismiss or timeout. |
| BDD-02 | passed | `Canaryd.ThermalMonitorTest` full test run | Pending observations clear after heat ends. |
| BDD-03 | passed | `Canaryd.ThermalMonitorTest` full test run | Protected processes do not get actions. |
