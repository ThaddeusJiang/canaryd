# Inconsistent Notification Logo

## What happened

Canaryd notifications did not use one app identity.
Some notifications showed the Script Editor icon.
Other notifications showed the generic macOS app icon.

## Root cause

Informational notifications used AppleScript `display notification`.
macOS assigned those notifications to the AppleScript host.
Temperature and action notifications used the bundled Canaryd helper.
The helper ran directly from Application Support and did not register its bundle with Launch Services before delivery.
Notification Center could not always resolve its custom icon.

## Fix applied

- Routed every Canaryd notification through the bundled helper.
- Registered the helper app bundle with Launch Services before delivery.
- Kept the existing notification text, timing, persistence, and actions.
- Added notifier and helper contract tests.
- Added a notification identity specification.

## What we learned

- Notification Center uses the sender app identity.
- An icon file does not fix notifications sent by another process.
- A helper outside Applications must register its bundle before notification delivery.
- Tests must cover every notification entry point.
