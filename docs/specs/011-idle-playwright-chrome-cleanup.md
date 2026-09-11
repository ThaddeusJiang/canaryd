# 011 Leftover Playwright Chrome Cleanup

Leftover Playwright Chrome for Testing cleanup specification.

## Purpose

Release graphics and WindowServer load held by forgotten Playwright Chrome for
Testing processes without terminating Google Chrome, Dia, Clicknow, the
frontmost window, or an in-progress Playwright run. Cleanup may run while the
user is still using the Mac.

## Scope

- In scope:
  - Current-user main `Google Chrome for Testing` processes whose executable
    lives under `Library/Caches/ms-playwright` and that are not frontmost.
  - Playwright runner protection, consecutive confirmation, exact-PID
    revalidation, local status, event history, and batched notifications.
- Out of scope:
  - Clicknow, Google Chrome, Chromium, Dia, and other browsers.
  - Chrome for Testing helper, renderer, GPU, and crashpad processes as
    independent close targets.
  - Chrome for Testing installed outside the Playwright cache.
  - The frontmost application.
  - Inferring which test, profile, or tab owns a browser.
  - Inspecting or persisting URLs, profile paths, or command-line arguments.
  - Forced termination with `SIGKILL`.
  - Requiring whole-Mac keyboard or pointer inactivity.

## Persistence

### Entities

- `IdlePlaywrightBrowserMonitor`
  - `observations`: A map keyed by fixed process kind, PID, and process start
    time with the latest bounded process snapshot and consecutive observation
    count.
- `PlaywrightBrowser`
  - `id`: A tuple of fixed process kind, PID, and process start time.
  - `kind`: The fixed supported process kind `chrome_for_testing`.
  - `pid`: The current process identifier.
  - `ppid`: The observed parent process identifier.
  - `started_at`: The process start time reported by `ps`.
  - `name`: A fixed display name derived from the supported kind.
- `Event`
  - Use the existing DETS event store with target `playwright_browsers`.
  - Store only bounded identity fields, observation count, and action result.
  - Never store the command line used for classification.

### Lifecycle

- A supported background browser observed with no Playwright runner present
  creates or advances a pending observation.
- An active Playwright runner, a frontmost browser, a missing process, an
  unavailable scan, or a changed process identity clears the incomplete
  sequence.
- Three consecutive observations produce one exact-PID termination action.
- The action rechecks Playwright runner absence, frontmost PID, and process
  identity before sending `SIGTERM`.
- A stopped, replaced, failed, or skipped target requires a new
  three-observation sequence before another action.

### Constraints

- Whole-Mac user idle is not required.
- Confirmation requires three consecutive five-minute full check rounds.
- Only current-user main Chrome for Testing processes under
  `Library/Caches/ms-playwright` are candidates.
- The frontmost application PID is never a candidate.
- One scan accepts at most 250 classified browsers and fails closed above that
  bound.
- Active current-user Playwright runners block the whole cleanup round.
- Actions use one positive PID and never use `pkill` or a name-only target.
- Termination never escalates from `SIGTERM` to `SIGKILL`.
- The monitor must not create atoms from process metadata.

## Relationships

- `Canaryd.Checker` runs the monitor during the five-minute full health check.
- `Canaryd.PlaywrightBrowsers` classifies supported browsers, discards command
  lines, detects Playwright runners, reads the frontmost PID, revalidates
  identity, and requests termination.
- Thermal, idle-memory, Simulator, Codex helper, unresponsive-app,
  build-cleanup, and CleanClip policies remain independent.

## Behavior

1. Read PID, parent PID, UID, start time, and command through `ps` without
   `sudo`.
2. Keep only current-user main Chrome for Testing processes whose path matches
   the Playwright cache signature.
3. Discard command-line data after classification.
4. Read the frontmost application PID through AppKit and drop that PID.
5. If the frontmost PID cannot be read, fail closed and do not terminate.
6. If any current-user Playwright runner is present, clear incomplete
   observations and do not terminate.
7. Require three consecutive eligible observations for the same kind, PID,
   and process start time.
8. Immediately before acting, recheck runner absence, frontmost PID, and
   identity.
9. Send `SIGTERM` to that exact PID and wait briefly for it to stop.
10. Never send `SIGKILL` and never use a broad process-name match.
11. Log detection, successful termination, skipped actions, and failed actions.
12. Batch successful or failed counts into at most one notification for each
    result class per check round.
13. Expose pending browsers through `canaryd status` and events through
    `canaryd history playwright`.

Runner protection, frontmost protection, and consecutive confirmation reduce
false positives, but they cannot prove that a headed debug session left in the
background will never be needed again. The fixed Playwright-cache path and
graceful exact-PID action bound the impact of that limitation.

## BDD Scenarios

### BDD-01 Stop leftover Chrome for Testing while the user is present

Given:
- The user may still be using the Mac.
- No current-user Playwright runner is present.
- A current-user main Chrome for Testing process remains under
  `Library/Caches/ms-playwright` and is not frontmost.

When:
- The same process kind, PID, and start time are observed for three consecutive
  full checks.

Then:
- Canaryd revalidates runner absence, frontmost PID, and the exact process
  identity.
- Canaryd sends `SIGTERM` to the exact PID.
- Canaryd logs the result and sends one batched notification for the round.

### BDD-02 Protect in-use, unrelated, and changed processes

Given:
- A Playwright runner is present, the browser is frontmost, or a process is a
  Chrome for Testing helper, crashpad, Google Chrome, Dia, Clicknow, owned by
  another user, stopped, or replaced under the same PID.

When:
- Canaryd evaluates or revalidates the process list.

Then:
- Canaryd does not send a termination signal to that process.
- A later supported leftover browser starts a new confirmation sequence.

### BDD-03 Fail closed when process state is unavailable

Given:
- Process inspection fails, the frontmost PID cannot be read, or the scan
  returns more than the bounded candidate count.

When:
- Canaryd runs a full check.

Then:
- Canaryd clears incomplete observations.
- Canaryd does not terminate any process from that scan.

## Cross-Spec Links

- [005 Time Unit Convention](./005-time-unit-convention.md)
- [008 Idle Simulator Shutdown](./008-idle-simulator-shutdown.md)
- [010 Idle Codex Process Cleanup](./010-idle-codex-process-cleanup.md)

## Open Questions

- Add a stronger per-browser activity signal only when Playwright exposes one
  with a stable, privacy-preserving identity.
