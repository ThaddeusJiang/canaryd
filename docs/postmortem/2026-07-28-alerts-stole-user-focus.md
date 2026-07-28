# Alerts Stole User Focus

## What happened

Canaryd used foreground alerts for temperature warnings and process actions.
The alerts took mouse focus from the active app.
The user had to dismiss a dialog before work could continue.

## Root cause

The implementation used AppleScript `display alert` because it could return a selected button.
The design treated reliable visibility as more important than noninterrupting delivery.
The feature specs also required foreground alerts and action dialogs.

## Fix applied

- Replaced foreground alerts with Notification Center notifications.
- Added a built-in macOS helper that uses the UserNotifications framework.
- Added Close and Restart actions to process notifications.
- Mapped notification dismiss and timeout to Ignore.
- Set the helper activation policy to accessory.
- Did not activate the helper app.
- Ran the helper through the standard `NSApplicationDelegate` lifecycle.
- Named the helper app Canaryd and added a canary app icon.
- Kept informational warnings in Notification Center until user dismissal.
- Kept the 120-second timeout only for actionable notifications.
- Added unit tests for warning and action notification commands.
- Added a Swift type check, helper signature check, and live notification run.

## What we learned

- A health monitor must not take input focus from the user.
- A dismiss action is a safe Ignore action.
- A macOS banner shows at most two custom actions.
- UserNotifications needs a bundled helper to receive action responses.
- UserNotifications authorization callbacks need the standard macOS application lifecycle.
- A compile check cannot replace a live notification run.
- An informational warning must stay in Notification Center until the user dismisses it.
- A scheduled notification is not proof that the user saw a banner.
