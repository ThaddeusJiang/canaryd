# 004 Notification Identity

Consistent macOS notification identity specification.

## Purpose

Show the Canaryd name and logo on every Canaryd notification.

## Scope

- In scope:
  - Informational notifications.
  - Persistent temperature warnings.
  - Notifications with Close and Restart actions.
  - Registration of the installed notification app with Launch Services.
- Out of scope:
  - Notification text changes.
  - Notification timing changes.
  - New notification actions.

## Relationships

- `Canaryd.Notifier` sends every notification through `Canaryd.NotificationHelper`.
- `Canaryd.Setup` installs the signed `Canaryd.app` notification helper.
- The helper registers its app bundle before it schedules a notification.

## Behavior

1. Send every Canaryd notification from the installed `Canaryd.app` helper.
2. Do not send a Canaryd notification from `osascript`.
3. Register the helper app bundle with Launch Services before notification delivery.
4. Use `Canaryd` as the bundle display name.
5. Use `Canaryd.icns` as the bundle icon.
6. Keep the existing notification text, timing, persistence, and actions.

## BDD Scenarios

### BDD-01 Show one identity for all notifications

Given:
- Canaryd needs to send an informational or actionable notification.

When:
- Canaryd schedules the notification.

Then:
- Canaryd uses the installed helper executable.
- The helper registers its app bundle.
- Notification Center can resolve the Canaryd name and logo.

Test Plan:
- Lowest useful level: unit tests for the notifier command contract and helper source.
- First failing test: an informational notification must call the helper executable.
- Follow-up test: the helper must register its bundle before delivery.

Acceptance Evidence:
- `Canaryd.NotifierTest`.
- `Canaryd.NotificationHelperTest`.
- Swift type check.
- Signed helper install.

## Cross-Spec Links

- [001 Unresponsive App Recovery](./001-unresponsive-app-recovery.md)
- [002 CleanClip Health Probe](./002-cleanclip-health-probe.md)
- [003 Thermal Process Monitor](./003-thermal-process-monitor.md)

## Acceptance Record

| Scenario | Status | Evidence | Notes |
| --- | --- | --- | --- |
| BDD-01 | passed | Focused ExUnit tests, Swift type check, signed helper install | All notifier paths use the Canaryd helper. |
