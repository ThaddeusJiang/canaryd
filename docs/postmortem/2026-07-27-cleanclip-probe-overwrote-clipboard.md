# CleanClip Probe Overwrote the Clipboard

## What happened

The scheduled CleanClip health probe replaced the general macOS pasteboard with a synthetic marker.
The probe did not restore the previous content.
Users could lose copied text, images, files, or rich content before paste.

## Root cause

The probe used the shared user pasteboard as a disposable test channel.
It had no snapshot and restore transaction.
It also had no protection for a user copy that occurred during the probe wait period.
The test suite did not cover pasteboard preservation.

## Fix applied

The probe now uses AppKit through the macOS JavaScript automation runtime.
It saves every pasteboard item and data type before it writes the marker.
It records the pasteboard change count after the marker write.
It restores the snapshot only when the change count stays unchanged.
It keeps newer content when another writer changes the pasteboard.
Named pasteboard tests cover restoration, concurrent writes, and command failure.

## What we learned

A synthetic probe must preserve shared user state.
A restore action must check for concurrent writes.
An operating system boundary needs an integration test that does not use live user data.
