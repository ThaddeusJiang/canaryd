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

## Initial fix applied

The probe used AppKit through the macOS JavaScript automation runtime.
It saved every pasteboard item and data type before it wrote the marker.
It recorded the pasteboard change count after the marker write.
It restored the snapshot only when the change count stayed unchanged.
It kept newer content when another writer changed the pasteboard.
Named pasteboard tests covered restoration, concurrent writes, and command failure.

## Follow-up change

The marker still polluted CleanClip history even when pasteboard restoration
worked. The current probe therefore reads the latest real CleanClip history
item and replays the same data. It accepts either a copy-count increase or a new
row with matching primary content bytes. Legacy `canaryd-probe-*` items are not
selected. The reversible pasteboard transaction
and concurrent-write protection remain in place.

## What we learned

A synthetic probe must preserve shared user state.
A restore action must check for concurrent writes.
An operating system boundary needs an integration test that does not use live user data.
