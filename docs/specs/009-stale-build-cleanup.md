# 009 Stale Build Cleanup

Daily cleanup specification for stale Xcode/Rust artifacts, orphaned Bazel
output bases, shared Bazel repository caches, and stale sccache objects.

## Purpose

Reclaim disk space from reproducible build outputs without deleting source,
archives, developer credentials, Simulator data, or active build artifacts.

## Scope

- In scope:
  - Direct children of `~/Library/Developer/Xcode/DerivedData`.
  - Cargo target directories below the current user's local development
    directories.
  - Current-user Cargo target directories directly under `/private/tmp`.
  - Bazel output bases under `~/Library/Caches/bazel/_bazel_*` whose recorded
    local workspace no longer exists.
  - Recognized download entries and extracted repositories under
    `~/Library/Caches/bazel/_bazel_*/cache/repos/v1`.
  - A daily launchd calendar schedule at 04:00 local time.
  - A manual `canaryd clean` command.
  - A per-user retention setting, defaulting to 24 hours, shared by scheduled
    and manual cleanup.
  - Local event history with counts, reclaimed bytes, and bounded skip reasons.
- Out of scope:
  - Xcode Archives, DeviceSupport, SDKs, UserData, signing identities, and
    certificates.
  - Simulator devices, runtimes, and application data.
  - Cargo registry, git cache, installed binaries, and source files.
  - Other build outputs outside the current user's home directory, and
    arbitrary projects nested under `/private/tmp`.
  - Bazel install caches, custom output
    roots, and workspaces outside the home directory or `/private/tmp`.
  - Arbitrary cleanup paths.

## Discovery

- Xcode candidates are direct child directories of DerivedData. Canaryd never
  treats the DerivedData root itself as a deletion candidate.
- Rust candidates are directories containing both Cargo's standard
  `CACHEDIR.TAG` signature and `.rustc_info.json`.
- Rust discovery scans non-hidden top-level directories in the user's home and
  `~/.codex/worktrees` and `~/.codex/workspace-backups` when present. It does not follow symbolic links and
  prunes dependency, VCS, and unrelated cache directories.
- Temporary Rust discovery inspects only direct children of `/private/tmp`;
  it does not recurse into temporary project containers. The directory and
  both regular Cargo markers must belong to the home directory's owner.
  Symlinked ancestry and cross-filesystem candidates or descendants are
  retained. The root-owned temporary directory is never a deletion candidate.
- Bazel candidates are direct output-base directories with a regular
  `DO_NOT_BUILD_HERE` marker of at most 4 KiB. Its absolute normalized workspace
  path must hash to the output-base directory's MD5 name. The candidate must
  belong to the home directory's owner; no cache ancestor may be a symlink.
- A Bazel workspace is missing only after a no-symlink component walk returns
  `enoent` inside the home directory or `/private/tmp`. Other errors, existing
  non-directory entries, dangling symlinks, and unsupported roots retain it.
- A missing or unreadable root is skipped without widening the search.
- Cargo discovery stays on the runtime home filesystem, including at each
  scan root and nested directory. NFS/virtual mounts such as `~/OrbStack` are
  not entered; a stalled container mount must not block local backup cleanup.
- Backup discovery removes only validated Cargo build directories. Backup
  containers, archives, unmerged changes, development data, test evidence, and
  sibling source files are not deletion candidates. Backups use the same
  configured full-tree retention and active Rust process checks as live projects.
- Revalidate backup path ancestry, markers, tree age, and processes immediately
  before removal. A symlink at any component below the runtime home blocks
  backup discovery and deletion. Remove artifacts incrementally without
  retaining a list of every removed file; only owned directory modes may change.
- Shared Bazel discovery recognizes the Bazel 9.2.0 repository-cache layout.
  Downloads are `content_addressable/<algorithm>/<digest>` directories with
  a regular `file` and optional matching canonical-id markers. Unknown
  algorithms, malformed digests, unfinished downloads, and unknown entries
  are retained. Extracted repositories are `contents/<hash>` directories
  containing complete UUID directory / `.recorded_inputs` file pairs.
  A recent entry retains its entire hash directory. The repository roots and
  `contents/gc_lock` are retained.

## Retention and Safety

The default retention is 24 hours. `canaryd config build-retention` shows the
effective value; `canaryd config build-retention 48h` saves a new duration.
Values are positive whole hours from `1h` to `87600h` (ten years), stored as
duration text in `~/Library/Application Support/canaryd/build-cleanup-retention`.
The file is read with a 64-byte limit and replaced atomically when settings
change. A missing file uses the default; malformed, oversized or unreadable
configuration stops cleanup before process inspection or candidate deletion.
Read the setting once per round under the cleanup lock and freeze that round's
cutoff. A setting changed during cleanup applies to the next round, without
changing the 04:00 schedule or requiring a restart. Configuration commands do
not start monitoring, install notification helpers or run cleanup.

1. Retain an Xcode/Cargo candidate when the directory or any descendant was modified
   within the configured retention period.
2. Delete an Xcode/Cargo candidate only when every entry in its tree has reached
   the configured retention period; the exact cutoff is eligible.
3. Skip all Xcode candidates while a current-user `Xcode`, `Simulator`,
   `xcodebuild`, or `xctest` process is active.
4. Skip all Rust candidates while a current-user `cargo` or `rustc` process is
   active. Independently retain a target containing any running executable,
   even when no compiler is active. Resolve executable aliases, preserve
   path-component boundaries, and treat uncertain activity as protection.
   A protected target does not block unrelated idle targets.
5. If process inspection is unavailable, delete nothing.
6. Recheck the relevant process class immediately before each deletion.
7. Never follow a symbolic link while discovering, measuring, or deleting a
   candidate.
8. Use a dedicated native exclusive lock so manual and scheduled cleanup
   cannot run concurrently. The lock file may remain on disk; only a live
   holder blocks cleanup. Process termination releases the lock automatically,
   and abandoned lock files from older versions do not block future runs.
9. Bazel orphan cleanup has no age threshold. An existing workspace always
   retains its output base, regardless of cache age.
10. A starting `bazel` or `bazelisk` client blocks the Bazel category. A resident
    named Bazel server protects its own output base via server PID and native lock
    checks; it does not block unrelated orphan cleanup. Missing PID files alone
    do not establish safety; malformed or symlinked server state retains the cache.
11. Each Bazel candidate gets fresh process inspection and workspace validation
    after measurement, after acquiring its native cache lock, and again after
    read-only directory preparation, immediately before removal. The Bazel PID snapshot is limited to five seconds and 8 MiB;
    failures and malformed output fail closed. Lock acquisition is nonblocking, with a five-second helper startup deadline.
    The existing regular `lock` file must be acquired exclusively with macOS `lockf`, without creating or replacing
    it. A missing, symlinked, changed, or busy lock retains the cache.
12. Only owned directories gain owner read/write/search permission when required
    to remove Bazel's read-only runfiles. File modes are never changed, including
    hard-linked artifacts. Symlink targets remain untouched.
13. The native lock protects against concurrent Bazel clients using the same
    lock file. Workspace recreation and filesystem changes by unrelated programs
    remain best-effort observations, not an atomic filesystem transaction.
14. Shared Bazel download and repository hash directories require the same
    configured retention without modification anywhere in their tree. Cache hits
    update the download `file` or extracted repository `.recorded_inputs` mtime; parent directory
    age alone never establishes eligibility.
15. Any Bazel client or resident server blocks shared repository cleanup.
    Acquire all known output-base locks, including bases whose workspaces still
    exist, then recheck the base set, process activity, candidate identity and
    tree age before removal. Missing, busy or unverifiable locks retain the
    shared cache. Running executables protect their repository hash directory.
16. Extracted repository cleanup also holds Bazel's native `contents/gc_lock`.
    Its upstream protocol allows creating a missing regular lock; never replace
    or truncate an existing one. Keep that lock and its parent directory after
    removing old hash directories. This creation rule does not apply to
    output-base locks.
17. Candidate inode, owner and filesystem identity are revalidated before
    deletion. Traversal does not cross filesystem boundaries or follow symlinks;
    shared regular-file modes are never changed. Activity command execution
    is bounded, and failures retain the affected category or candidate.
18. Download caches have no common native GC lock. The activity checks and
    known output-base locks cannot atomically prevent a new output base or
    custom-root Bazel client starting after the last check. This is a
    best-effort concurrency boundary, not a guarantee against every external
    filesystem mutation.
19. Shared-cache cleanup is incremental. A user-cache batch considers at most
    16 eligible hashes and has a 15-second soft budget; the whole repository
    round has a 60-second soft budget. Candidate order varies across runs,
    including download algorithms and extracted repositories, without a
    persistent cursor. Activity is freshly checked for each candidate, and
    changed or busy shared state ends the batch. Check budgets at safe
    boundaries and release native locks on exit; an already-started tree
    operation may finish after the deadline.

## Behavior

1. At 04:00 local time, launchd runs `canaryd clean`.
2. Installing the calendar agent does not immediately run cleanup.
3. Canaryd discovers validated candidates within the fixed safe roots.
4. Canaryd checks current-user build processes and the full candidate tree
   activity before deletion.
5. Canaryd measures candidate bytes without following symbolic links.
6. Canaryd removes validated stale Xcode/Cargo candidates, idle Bazel output
   bases with a missing local workspace, and eligible stale shared repository
   entries under their separate activity and lock checks.
7. Canaryd prints removed paths, reclaimed bytes, skips, and failures to its
   local launchd log.
8. Canaryd records one `builds` history event containing counts, estimated reclaimed
   bytes, and bounded reasons including `bazel_skip`. Paths are not persisted in DETS.

## BDD Scenarios

### BDD-01 Remove stale reproducible outputs

Given:
- A DerivedData child and a validated Cargo target have no modification in the
  last 24 hours, with no custom retention configured.
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
- The user runs `canaryd start` to install or refresh its launchd configuration.

When:
- The launchd agents are rendered.

Then:
- The full health check retains its five-minute interval.
- A separate build-cleanup agent uses `StartCalendarInterval` with hour 4 and
  minute 0.
- The build-cleanup agent does not use `RunAtLoad`.

### BDD-05 Remove orphaned Bazel caches

Given a valid Bazel output base records a missing local workspace, when the
cleanup runs with no activity in that cache, then the output base is removed
regardless of age. Existing workspaces keep their output bases. Shared
repository entries follow the separate stale-cache policy; install caches stay.

### BDD-06 Retain busy or unverifiable Bazel caches

Given an output base has a live server PID, a held native lock, malformed server
state, a symlinked/malformed marker, or an unsupported workspace root, then it is
retained. Failure to inspect processes retains the category. A resident server
in another output base does not prevent removal of an unrelated orphan.

### BDD-07 Revalidate and handle read-only artifacts

Given a workspace reappears or cache activity begins during inspection, then
removal is skipped. Otherwise read-only runfiles directories can be removed,
while symlink targets and modes of hard-linked files outside the cache stay intact.

## Acceptance Evidence

- `Canaryd.BuildCleanupTest` candidate, retention, process protection, lock,
  and deletion tests.
- `Canaryd.BazelCacheTest` identity, path boundaries, server state, native lock exclusion/release, process-output parsing, command output
  bounds, and timeout tests.
- `Canaryd.SetupTest` interval and calendar schedule tests.
- `Canaryd.RuntimePathsTest` clean-command deletion and bounded history event.
- Relevant CLI, runtime path, naming convention, and full test suite checks.

## Cross-Spec Links

- [003 Thermal Process Monitor](./003-thermal-process-monitor.md)
- [005 Time Unit Convention](./005-time-unit-convention.md)
- [008 Idle Simulator Shutdown](./008-idle-simulator-shutdown.md)

### BDD-08 Remove only stale build artifacts from workspace backups

Given:
- A Codex workspace backup contains a validated Cargo target untouched for
  the configured retention alongside unmerged changes, an archive, and recent build output.
- No protected Rust process is active.

When:
- The daily `canaryd clean` run discovers its default roots.

Then:
- Only the stale target is removed; the backup and other files remain.
- Active builds, recent descendants, symlinked ancestors, and an ancestry
  change during revalidation prevent deletion.
- Read-only build directories can be removed without changing the permissions
  or content of shared artifact hard links outside the candidate.

Acceptance: `Canaryd.BuildCleanupTest` backup discovery, retention, process,
ancestry, read-only directory, and hard-link scenarios; `Canaryd.RuntimePathsTest`
CLI cleanup and bounded history integration; `Canaryd.SetupTest` daily schedule.

### BDD-09 Clean temporary Cargo targets without removing running services

Given old, current-user Cargo targets directly under `/private/tmp`, a temporary
source project, and a service running from one home or temporary target, when
cleanup runs without a compiler, only the idle validated target is removed.
The service target, source project, recent descendants, foreign-owned markers,
symlinked paths, replaced candidates and filesystem mounts are retained.
Unverifiable process activity prevents removal; a service appearing during
revalidation also protects its target.

### BDD-10 Reclaim old shared Bazel repository entries

Given recent and old recognized download entries and extracted repository
hashes in the same shared cache, when all Bazel activity is idle and native
locks are available, only the old entries are removed. Unknown layouts,
incomplete pairs, busy or changed locks, new output bases, running executables
and unavailable activity checks prevent deletion. Read-only artifacts are
removed without changing outside hard links or following symlinks. The native
GC lock remains available for the next Bazel run.

Given more old entries than one batch can handle, cleanup stops at its count
or time budget and releases native locks. Later runs can select other entries;
the budget never permits reuse of a stale idle-process decision.

Acceptance: `Canaryd.BuildCleanupTest`, `Canaryd.ArtifactProcessesTest`,
`Canaryd.ArtifactTreeTest`, `Canaryd.BazelRepositoryCacheTest`, and the real
CLI/history integration in `Canaryd.RuntimePathsTest`.

### BDD-11 Configure retention with a 24-hour default

With no saved setting, Xcode, temporary Cargo and shared Bazel trees at exactly
24 hours are eligible; a descendant one second newer keeps its whole candidate.
After saving `48h`, the same 36-hour-old candidates remain across invocations.
A change to `24h` during a round takes effect only on the next round. Reading
and changing settings preserves the existing monitoring lifecycle.

Invalid command values preserve the saved setting. Invalid persisted values
stop cleanup before process scanning or artifact deletion. Configuration I/O
uses the same runtime home as cleanup, including isolated test homes.

Acceptance: retention boundary and saved-cutoff scenarios in
`Canaryd.BuildCleanupTest`; persistence and validation in
`Canaryd.BuildCleanupConfigTest`; CLI setting and lifecycle checks in
`Canaryd.BuildCleanupConfigCLITest`.

## Shared Cache Protocol References

- [Bazel 9.2.0 download cache](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/bazel/repository/cache/DownloadCache.java)
- [Bazel 9.2.0 extracted repository cache](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/bazel/repository/cache/LocalRepoContentsCache.java)
- [Bazel 9.2.0 filesystem lock](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/util/FileSystemLock.java)

## sccache objects

- Clean only owned, regular `x/y/<64 lowercase hex>` objects in the default
  `~/Library/Caches/Mozilla.sccache` root, with matching first two digest digits.
  Validate every ancestor without following symlinks or crossing filesystems.
- Use the shared retention cutoff against both mtime and atime. sccache 0.17
  refreshes both on reads; preserve recent or currently open objects.
- Inspect current-user compiler processes and PID-scoped sccache open files
  before cleanup and each bucket. Fail closed if inspection fails or a compiler
  is active; revalidate file identity, ownership and timestamps before unlink.
- Do not stop/restart sccache, touch preprocessor or temporary files, or follow
  custom cache locations. Concurrent cache requests can fall back to rebuilding
  evicted objects. In-memory sccache size accounting may lag physical deletion.
- Bound command output, per-bucket entries (10,000), removed objects (10,000)
  and round duration (30 seconds soft, allowing an in-flight bounded command).
  Randomize bucket order to prevent persistent prefix starvation.
- Report removed/kept object counts, logical bytes, failures and skip reason in
  CLI output and cleanup event history. Logical bytes are not APFS free space.

Validation: fixture tests cover age/access time, saved retention, symlinks,
open files, compiler activity, inspection failure, revalidation and budgets.
