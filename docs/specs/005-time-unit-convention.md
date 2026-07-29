# 005 Time Unit Convention

System time unit specification.

## Purpose

Use one time unit for every internal duration.
Convert values only at framework or operating system boundaries.

## Scope

- In scope:
  - Elixir duration constants and function arguments.
  - DateTime duration comparisons.
  - Event detail duration values.
  - Notification helper command arguments.
  - macOS HID, launchd, JXA, Swift Timer, and macmon boundaries.
- Out of scope:
  - Calendar dates and wall-clock timestamps.
  - Human-readable duration text in CLI output and documentation.

## Contract

- Milliseconds are the only internal time unit.
- A variable name describes its domain purpose. It does not include a unit suffix.
- `Canaryd.Duration` creates internal duration values.
- Elixir and OTP timer calls receive internal duration values without conversion.
- DateTime comparisons use milliseconds.
- An adapter converts a duration when an external API uses another unit.
- The adapter keeps the conversion next to the external API call.
- Human-readable output can use seconds or minutes after an explicit boundary conversion.

## Boundary Rules

- Convert macOS HID nanoseconds to milliseconds when the value enters Canaryd.
- Convert milliseconds to launchd seconds when Canaryd renders `StartInterval`.
- Pass milliseconds to the notification helper command.
- Convert milliseconds to Swift `TimeInterval` seconds at the `Timer` call.
- Convert milliseconds to JXA delay seconds at the `delay` call.
- Pass milliseconds to macmon without conversion.

## BDD Scenario

### BDD-01 Keep one internal time unit

Given:
- Canaryd has duration values from Elixir and macOS APIs.

When:
- Canaryd compares, stores, or passes a duration inside the application.

Then:
- The value uses milliseconds.
- A different unit exists only inside an external boundary conversion.
- Time variable names do not use unit suffixes.

Test Plan:
- Lowest useful level: unit tests for duration creation and each conversion boundary.
- First failing test: duration helpers and boundary contracts expect millisecond values.
- Regression test: repository naming and DateTime checks reject old patterns.

## Acceptance Record

| Scenario | Status | Evidence | Notes |
| --- | --- | --- | --- |
| BDD-01 | passed | `Canaryd.DurationTest`, boundary contract tests, naming convention tests, full test run, Swift type check | Canaryd uses milliseconds internally and converts only at external boundaries. |
