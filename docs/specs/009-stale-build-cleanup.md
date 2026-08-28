# 009 Stale Build Cleanup

Daily cleanup specification for stale Xcode and Rust build artifacts.

## Purpose

Reclaim disk space from reproducible build outputs without deleting source,
archives, developer credentials, Simulator data, or active build artifacts.

## Scope

- In scope:
  - Direct children of `~/Library/Developer/Xcode/DerivedData`.
  - Cargo target directories below the current user's local development
    directories.
  - A daily launchd calendar schedule at 04:00 local time.
  - A manual `canaryd cleanup-builds` command.
  - Local event history with counts, reclaimed bytes, and bounded skip reasons.
- Out of scope:
  - Xcode Archives, DeviceSupport, SDKs, UserData, signing identities, and
    certificates.
  - Simulator devices, runtimes, and application data.
  - Cargo registry, git cache, installed binaries, and source files.
  - Build outputs outside the current user's home directory.
  - Configurable retention periods or arbitrary cleanup paths.

## Discovery

- Xcode candidates are direct child directories of DerivedData. Canaryd never
  treats the DerivedData root itself as a deletion candidate.
- Rust candidates are directories containing both Cargo's standard
  `CACHEDIR.TAG` signature and `.rustc_info.json`.
- Rust discovery scans non-hidden top-level directories in the user's home and
  `~/.codex/worktrees` when present. It does not follow symbolic links and
  prunes dependency, VCS, and unrelated cache directories.
- A missing or unreadable root is skipped without widening the search.

## Retention and Safety

1. Retain a candidate when the directory or any descendant was modified less
   than seven days ago.
2. Delete a candidate only when every entry in its tree is at least seven days
   old.
3. Skip all Xcode candidates while a current-user `Xcode`, `Simulator`,
   `xcodebuild`, or `xctest` process is active.
4. Skip all Rust candidates while a current-user `cargo` or `rustc` process is
   active.
5. If process inspection is unavailable, delete nothing.
6. Recheck the relevant process class immediately before each deletion.
7. Never follow a symbolic link while discovering, measuring, or deleting a
   candidate.
8. Use a dedicated exclusive lock so manual and scheduled cleanup cannot run
   concurrently.

## Behavior

1. At 04:00 local time, launchd runs `canaryd cleanup-builds`.
2. Installing the calendar agent does not immediately run cleanup.
3. Canaryd discovers validated candidates within the fixed safe roots.
4. Canaryd checks current-user build processes and the full candidate tree
   activity before deletion.
5. Canaryd measures candidate bytes without following symbolic links.
6. Canaryd removes only validated stale candidates.
7. Canaryd prints removed paths, reclaimed bytes, skips, and failures to its
   local launchd log.
8. Canaryd records one `builds` history event containing counts, reclaimed
   bytes, and bounded reasons. Paths are not persisted in DETS.

## BDD Scenarios

### BDD-01 Remove stale reproducible outputs

Given:
- A DerivedData child and a validated Cargo target have no modification in the
  last seven days.
- No protected build process is active.

When:
- The cleanup command runs.

Then:
- Canaryd removes both candidate directories.
- Canaryd reports their paths and reclaimed bytes.
- Source and every out-of-scope location remain unchanged.

### BDD-02 Retain recent or unverifiable data

Given:
- A candidate contains a recently modified descendant, is a symbolic link, or
  lacks the Cargo markers.

When:
- The cleanup command runs.

Then:
- Canaryd does not remove that path.

### BDD-03 Protect active builds

Given:
- A protected Xcode or Rust build process is active, or process inspection is
  unavailable.

When:
- The cleanup command runs.

Then:
- Canaryd skips the affected build class, or all cleanup when inspection is
  unavailable.
- Canaryd records the bounded skip reason.

### BDD-04 Run once daily at 04:00

Given:
- Canaryd installs or self-heals its launchd configuration.

When:
- The launchd agents are rendered.

Then:
- The full health check retains its five-minute interval.
- A separate build-cleanup agent uses `StartCalendarInterval` with hour 4 and
  minute 0.
- The build-cleanup agent does not use `RunAtLoad`.

## Acceptance Evidence

- `Canaryd.BuildCleanupTest` candidate, retention, process protection, lock,
  and deletion tests.
- `Canaryd.SetupTest` interval and calendar schedule tests.
- Relevant CLI, runtime path, naming convention, and full test suite checks.

## Cross-Spec Links

- [003 Thermal Process Monitor](./003-thermal-process-monitor.md)
- [005 Time Unit Convention](./005-time-unit-convention.md)
- [008 Idle Simulator Shutdown](./008-idle-simulator-shutdown.md)
