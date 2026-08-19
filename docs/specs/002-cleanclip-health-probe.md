# 002 CleanClip Health Probe

CleanClip functional health probe specification.

## Purpose

Verify that CleanClip records clipboard activity without adding synthetic
`canaryd-probe-*` content to clipboard history.

## Scope

- In scope:
  - Read the latest replayable real item from CleanClip's local history store.
  - Replay every stored pasteboard data type for that item.
  - Detect success from byte-equivalent duplicate content in a new history row
    or an increased copy count on the selected row.
  - Preserve the user's current pasteboard content.
  - Ignore legacy `canaryd-probe-*` history items when selecting an item.
- Out of scope:
  - Delete legacy synthetic history items.
  - Recover content that another process already removed.
  - Diagnose other pasteboard writers.
  - Change CleanClip settings or history directly.

## Persistence

The probe does not add canaryd state.
CleanClip may add a new row or increase the copy count of an existing real
history item. Duplicate real content is acceptable.

## Relationships

- `Canaryd.Checker` runs the probe during each active check round.
- CleanClip's Core Data store identifies recent reusable history items and
  records new rows or copy-count changes.
- CleanClip's history content directory stores the original data for every
  pasteboard type.
- The general macOS pasteboard supplies the transaction boundary.

## Behavior

1. Read the latest replayable CleanClip history item that is not a legacy
   `canaryd-probe-*` item. Skip recent items with missing content files.
2. Read every stored content type for that item.
3. Save all current pasteboard items and data types.
4. Replay the selected CleanClip item on the general pasteboard.
5. Record the pasteboard change count and wait for CleanClip to observe it.
6. Restore the saved pasteboard only when no newer pasteboard write occurred.
7. Keep newer content when a user or another process changes the pasteboard
   during the wait.
8. Pass when CleanClip either increases the selected item's copy count or adds
   a new item with matching primary content bytes.
9. Report a probe failure when history data is unavailable, the pasteboard
   transaction fails, or no duplicate content appears.

## BDD Scenarios

### BDD-01 Replay a real CleanClip history item

Goal:
- Verify CleanClip without generating synthetic clipboard content.

Given:
- CleanClip history contains at least one real item.
- The item has one or more stored pasteboard data types.

When:
- canaryd runs the CleanClip functional probe.

Then:
- canaryd replays every stored data type from the latest real item.
- canaryd does not create a `canaryd-probe-*` value.
- legacy probe items are not selected for replay.

Test Plan:
- Lowest useful level: SQLite-backed history integration test and named
  pasteboard integration test.
- First failing test: select the latest non-probe item and resolve every stored
  type.
- Follow-up tests: replay every type from files on a named pasteboard.

Acceptance Evidence:
- Focused ExUnit tests.
- One live CleanClip probe with no new synthetic value.

### BDD-02 Confirm duplicate content

Goal:
- Require evidence that CleanClip observed the replay.

Given:
- The selected history item has known content and a known copy count.

When:
- canaryd replays that item.

Then:
- The probe passes when the same item's copy count increases.
- The probe also passes when CleanClip creates a new row with matching primary
  content bytes because its source application differs.
- `:no_duplicate_history_item` is returned when neither condition occurs.

Test Plan:
- Lowest useful level: SQLite-backed history integration tests and a unit test
  with injected history and pasteboard boundaries.
- First failing test: a new row with matching types and bytes passes.
- Follow-up tests: copy-count increase, omitted secondary files, and different
  content.

Acceptance Evidence:
- Focused ExUnit tests.
- Live duplicate-row verification.

### BDD-03 Preserve pasteboard content

Goal:
- Keep the content that the user expects to paste.

Given:
- The general pasteboard contains one or more items.

When:
- canaryd replays a CleanClip history item.

Then:
- canaryd restores every saved item and data type when the replay remains
  unchanged.
- a newer user or process write always wins.

Test Plan:
- Lowest useful level: JXA integration test with a named pasteboard.
- First failing test: restore text and custom data after replay.
- Follow-up tests: preserve a concurrent newer write.

Acceptance Evidence:
- Focused named-pasteboard integration tests.

### BDD-04 Report probe failures

Goal:
- Keep the health check process alive when the probe cannot run.

Given:
- CleanClip history is empty or unreadable, no recent item is replayable, the
  pasteboard command fails, or no duplicate content appears.

When:
- canaryd runs the probe.

Then:
- The probe returns a failure reason.
- The checker applies its existing recovery policy.

Test Plan:
- Lowest useful level: boundary unit and integration tests.
- First failing test: missing history content returns a history error.
- Follow-up tests: command failure and missing duplicate content.

Acceptance Evidence:
- Focused ExUnit tests.

## Search

- Not applicable.

## AI

- Not applicable.

## Cross-Spec Links

- [001 Unresponsive App Recovery](./001-unresponsive-app-recovery.md)
- [004 Notification Identity](./004-notification-identity.md)

## Open Questions

- None.

## Acceptance Record

| Scenario | Status | Evidence | Notes |
| --- | --- | --- | --- |
| BDD-01 | passed | history selection test; named-pasteboard replay test; live probe returned `:ok` without changing legacy probe metrics | Legacy probe values were not selected or updated |
| BDD-02 | passed | matching-row, copy-count, omitted-secondary-file, and different-content tests; live duplicate-row probe | CleanClip can create a new row when the source application differs |
| BDD-03 | passed | named-pasteboard restoration and concurrent-write tests | Text and custom data verified |
| BDD-04 | passed | missing content, command failure, and unchanged-count tests | Boundary failures verified |
