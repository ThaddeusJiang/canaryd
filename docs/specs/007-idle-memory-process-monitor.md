# 007 High-Memory Application Alerts

## Purpose

Report sustained memory use without closing ordinary applications. User inactivity,
low CPU, and a large RSS do not establish that background work or unsaved documents
can be discarded. This policy replaces the previous idle-memory auto-close policy.

## Behavior

- Run on every full check, independently of keyboard or pointer activity.
- Aggregate current-user processes under registered top-level third-party app bundles.
- Preserve existing exclusions for foreground apps, Apple/system apps, nested helpers,
  unregistered commands, and other users.
- Observe apps using at least 1,024 MB aggregate RSS and at most 1% aggregate CPU.
- Require three observations, spaced at least five minutes apart, for the same app
  identity and main PID. A scan gap over ten minutes, backwards clock, failed scan,
  PID change, lower RSS, or CPU activity resets confirmation.
- Notify at most once per app per hour. Never request termination for memory use.
- Retain the existing `idle_memory_processes` DETS key for status compatibility.
  New observations carry timestamps; legacy untimed observations restart confirmation.
  Old close timestamps are not reused as alert timestamps.
- Log `high_memory_detected` and `high_memory_alerted` under `canaryd history memory`.
  Existing historical close events remain readable.
- Store aggregate measurements and app identity only, never document contents or
  command-line arguments.

## Validation

`MemoryMonitorTest` covers sustained use, cooldown, protected apps, PID replacement,
rapid calls, unavailable/changed activity, gaps, backwards clocks, and legacy state.
`MemoryProcessesTest` covers bundle aggregation and eligibility. The memory scanner
has no application termination API. Thermal actions selected by the user and the
separate unresponsive-app policy remain independent.

## Cross-Spec Links

- [003 Thermal Process Monitor](./003-thermal-process-monitor.md)
- [005 Time Unit Convention](./005-time-unit-convention.md)
