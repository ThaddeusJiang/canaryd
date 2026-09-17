<p align="center">
  <img src="https://raw.githubusercontent.com/ThaddeusJiang/canaryd/main/priv/canaryd-logo.png" width="152" alt="Canaryd logo">
</p>

<h1 align="center">canaryd</h1>

<p align="center">
  A quiet health monitor for developer Macs.
  <br>
  It catches stalled services, forgotten Simulators and screen-control helpers,
  silent utilities, heat, idle memory, and stale build output — then recovers
  what it safely can.
</p>

<p align="center">
  <a href="https://hex.pm/packages/canaryd"><img src="https://img.shields.io/hexpm/v/canaryd?style=flat-square&color=F5B700" alt="Hex package version"></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-243447?style=flat-square" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/platform-macOS-243447?style=flat-square" alt="macOS">
  <img src="https://img.shields.io/badge/Elixir-1.15%2B-6E4A7E?style=flat-square" alt="Elixir 1.15 or later">
</p>

<p align="center">
  <a href="#why-canaryd-exists">Stories</a> ·
  <a href="#status-at-a-glance">Status</a> ·
  <a href="#install">Install</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#safety-model">Safety</a>
</p>

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/canaryd-core-stories/output/publish/canaryd-core-stories.mp4?raw=1" data-poster="./hyperframes-src/canaryd-core-stories/output/publish/poster.png">
    <img src="./hyperframes-src/canaryd-core-stories/output/publish/canaryd-core-stories.gif" width="860" alt="Canaryd recovers six common developer-Mac problems">
  </a>
  <br>
  <sub>The 20-second story reel plays inline. Click it for the MP4.</sub>
</p>
<!-- readme-video:end -->

---

Canaryd is a local macOS watchdog. Every five minutes it checks real system and
application behavior; once a day it reclaims validated stale build output. It
confirms suspicious state before acting and keeps successful background
recovery quiet. State, events, and logs stay on the Mac.

## Why Canaryd exists

### 1. `CursorUIViewService` hangs again

`CursorUIViewService` is an Apple text-input XPC service. Despite its name, it
is unrelated to the Cursor editor. When the service stalls, macOS marks it as
Not Responding and ordinary process-liveness checks still see a running PID.

On one developer Mac, Canaryd recorded eight confirmed hangs and eight
successful recoveries in a day. Canaryd matches the exact Apple service
identity, confirms the hang twice, stops only the stale instance, and waits for
a replacement PID. It does not restart the editor, switch apps, or show a
foreground alert.

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/canaryd-core-stories/output/publish/stories/cursoruiviewservice-recovery/cursoruiviewservice-recovery.mp4?raw=1" data-poster="./hyperframes-src/canaryd-core-stories/output/publish/frames/cursoruiviewservice-recovery.png">
    <img src="./hyperframes-src/canaryd-core-stories/output/publish/stories/cursoruiviewservice-recovery/cursoruiviewservice-recovery.gif" width="860" alt="CursorUIViewService changes from Not Responding to a replacement process after quiet Canaryd recovery">
  </a>
  <br>
  <sub>The recovery story plays inline. Click it for the MP4.</sub>
</p>
<!-- readme-video:end -->

### 2. An AI agent finishes, but its Simulators keep running

An AI coding agent can build and test several iOS device profiles, then leave
the booted Simulators behind after the task ends. One real investigation found
three booted devices that had been running for 15 hours to more than a day,
with 742 processes across their Simulator trees.

Canaryd keeps scanning while the Mac is in use. It starts a 15-minute inactivity
window from the later of the device's `lastUsedAt` timestamp and the most recent
time Simulator was in the foreground. The first five-minute check after that
fixed window can shut down the device. An active `xcodebuild` or `xctest`
process blocks recovery. Before running `simctl shutdown <UDID>`, Canaryd
rechecks the foreground application, automation, and exact device. It never
erases, deletes, or resets device data.

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/canaryd-core-stories/output/publish/stories/idle-simulators/idle-simulators.mp4?raw=1" data-poster="./docs/assets/notifications/simulators-shut-down.png">
    <img src="./hyperframes-src/canaryd-core-stories/output/publish/stories/idle-simulators/idle-simulators.gif" width="860" alt="Canaryd shuts down three validated idle Simulators after an AI agent finishes">
  </a>
  <br>
  <sub>The idle-Simulator story plays inline. Click it for the MP4.</sub>
</p>
<!-- readme-video:end -->

<p align="center">
  <img src="./docs/assets/notifications/simulators-shut-down.png" width="430" alt="Canaryd notification showing idle Simulators shut down">
  <br>
  <sub>Representative capture from macOS Notification Center.</sub>
</p>

### 3. Codex screen-control helpers multiply

A real Activity Monitor snapshot showed twelve visible `SkyComputerUseClient`
processes at once. A broad name-based cleanup would be easy to write, but it
could terminate helpers that still belong to active work.

Canaryd observes cumulative CPU time and process identity for 30 minutes.
Childless REPL and CUA hosts can qualify while you keep using the Mac; helpers
with execution kernels or other child processes stay protected. Connected
legacy MCP adapters still require whole-Mac inactivity. Before sending
`SIGTERM`, Canaryd checks the exact PID, start time, parent, CPU counter, and
children again. It never uses `pkill` or `SIGKILL`.

Run `canaryd reclaim --dry-run` to see candidates and why others are kept.
`canaryd reclaim` uses the same confirmation window as scheduled checks; it
cannot force termination. Reclaimed tool connections may require reconnecting
or reopening their task. Process cleanup is independent of build retention.

The recording below demonstrates the earlier whole-Mac-idle policy.

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/codex-screen-control-cleanup/output/codex-screen-control-cleanup.mp4?raw=1" data-poster="./hyperframes-src/codex-screen-control-cleanup/output/poster.png">
    <img src="./hyperframes-src/codex-screen-control-cleanup/output/codex-screen-control-cleanup.gif" width="860" alt="Activity Monitor shows twelve visible SkyComputerUseClient processes before Canaryd demonstrates its bounded cleanup policy">
  </a>
  <br>
  <sub>The 17.5-second demo plays inline. Click it for the MP4 with sound. The cleanup sequence is controlled.</sub>
</p>
<!-- readme-video:end -->

### 4. CleanClip is alive, but it stopped recording

In a real failure, CleanClip stayed running with 0% CPU and no crash report,
but its clipboard history had not changed for more than two days. New copy
operations were no longer recorded. A process check said healthy; the feature
was dead.

Canaryd replays the latest usable real CleanClip history item and verifies that
matching content appears in history. It saves every current pasteboard item and
data type first. If the user copies something during the probe, the newer user
content always wins. A failed probe triggers a quiet restart.

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/canaryd-core-stories/output/publish/stories/cleanclip-functional-probe/cleanclip-functional-probe.mp4?raw=1" data-poster="./hyperframes-src/canaryd-core-stories/output/publish/frames/cleanclip-functional-probe.png">
    <img src="./hyperframes-src/canaryd-core-stories/output/publish/stories/cleanclip-functional-probe/cleanclip-functional-probe.gif" width="860" alt="Canaryd detects that CleanClip is alive but its history is stale, runs a reversible functional probe, and confirms recovery">
  </a>
  <br>
  <sub>The functional-health story plays inline. Click it for the MP4.</sub>
</p>
<!-- readme-video:end -->

### 5. An AI coding session heats the Mac

Xcode can keep indexing, compiling, or running build services long after the
developer expected the expensive work to finish. Simulator processes can add
more load at the same time. The result is a familiar developer-Mac problem:
high CPU use, rising temperature, and no clear answer about which process is
driving it.

On Apple Silicon, Canaryd takes three `macmon 0.8.0` samples and keeps the
highest CPU and GPU average. It also checks thermal throttling and system load,
then lists up to five processes using at least 20% CPU. A safe top-level app can
receive Close and Restart actions; a runtime or system process is reported as
a suspect without an automatic action. CPU use is correlation evidence, not
exact heat attribution.

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/canaryd-core-stories/output/publish/stories/thermal-pressure/thermal-pressure.mp4?raw=1" data-poster="./docs/assets/notifications/thermal-action.png">
    <img src="./hyperframes-src/canaryd-core-stories/output/publish/stories/thermal-pressure/thermal-pressure.gif" width="860" alt="Canaryd reports thermal pressure, contributing processes, and safe actions after a coding session">
  </a>
  <br>
  <sub>The thermal-pressure story plays inline. Click it for the MP4.</sub>
</p>
<!-- readme-video:end -->

<p align="center">
  <img src="./docs/assets/notifications/thermal-action.png" width="430" alt="Canaryd high-temperature notification showing Xcode and Simulator as CPU-related heat suspects with Close and Restart actions">
  <br>
  <sub>Representative capture from macOS Notification Center.</sub>
</p>

### 6. Work is over, but a memory-heavy app is still open

Developer tools often use several processes, so one quiet application can hold
far more memory than its main PID suggests. During one investigation, a
Nowledge Mem background server stayed around 1 GB RSS and frequently fell to
0% CPU. Browser-style tools such as Dia and ChatGPT showed the same multi-process
shape. These are typical candidates after the user walks away, not while they
are active workspaces.

Canaryd aggregates an application's process tree. After 30 minutes of user
inactivity, a non-active third-party app becomes eligible only when it stays at
or above 1 GB RSS and at or below 1% CPU for three consecutive checks. Canaryd
then requests a graceful close. It protects the active app, Apple apps, system
processes, and helper bundles, and never escalates this recovery to `SIGKILL`.

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/canaryd-core-stories/output/publish/stories/idle-memory-recovery/idle-memory-recovery.mp4?raw=1" data-poster="./hyperframes-src/canaryd-core-stories/output/publish/frames/idle-memory-recovery.png">
    <img src="./hyperframes-src/canaryd-core-stories/output/publish/stories/idle-memory-recovery/idle-memory-recovery.gif" width="860" alt="Canaryd confirms that a third-party app is inactive, using more than one gigabyte of memory, and safe to close gracefully">
  </a>
  <br>
  <sub>The idle-memory story plays inline. Click it for the MP4. It is based on a real high-memory candidate.</sub>
</p>
<!-- readme-video:end -->

### 7. AI agents finish, but their build output stays

Parallel coding agents can leave Xcode DerivedData, Cargo `target/` directories,
and Bazel output bases after their tasks are complete. Deleting a worktree does
not remove its Bazel cache, and workspace backups can retain build artifacts. The
source may already be committed while reproducible build output continues to
consume disk space.

At 04:00 local time, Canaryd checks fixed safe roots, validates every candidate,
and requires Xcode/Cargo directory trees to be untouched for 24 hours by default. It
skips Xcode cleanup while Xcode, Simulator, `xcodebuild`, or `xctest` is active,
and skips Rust cleanup while `cargo` or `rustc` is active. A service or other
executable running from a Cargo target also protects that target. It never
follows symbolic links or removes source, Archives, Simulator data, or Cargo
registry caches.

Cargo discovery includes `~/.codex/workspace-backups` as well as live projects
and Codex worktrees, plus Cargo targets directly under `/private/tmp`.
Temporary targets must belong to the current user and contain both Cargo
markers; temporary project containers are not searched recursively.
Only validated Cargo build directories are eligible;
backup archives, unmerged changes, development data, and test evidence remain.
The configured retention and active-build checks also apply to backup artifacts.

The same daily run removes Bazel output bases only when their workspace marker
and directory hash agree, and the recorded local workspace no longer exists.
An existing workspace always keeps its cache. Canaryd rechecks server PIDs,
the native cache lock, and the missing workspace before deletion. Busy or
unverifiable output bases remain untouched.
Orphaned Bazel output bases do not have an age threshold.

Shared Bazel repository caches use the same configured retention: old download
entries and extracted repository hash directories can be reclaimed while
recent entries stay. Cleanup requires no active Bazel client or server, locks
all known output bases, and uses Bazel's `contents/gc_lock` for extracted
repositories. Running executables protect their cache directories. Unknown
layouts and unavailable activity checks retain the cache; install caches stay.
Shared-cache cleanup is incremental: each user cache gets up to 16 eligible
hashes and a 15-second soft budget, within a 60-second round budget. Candidate
order varies across runs so one protected prefix does not monopolize cleanup.
An in-progress tree operation can finish after the budget; locks are released
before a later round retries the remainder.
The same run cleans completed sccache objects in
`~/Library/Caches/Mozilla.sccache` after the configured retention (24h by default).
Recent or open objects, preprocessor data, temporary writes and custom cache
locations remain. Active compiler processes or unavailable inspection skip
sccache cleanup. Each round removes up to 10,000 objects within a 30-second soft
budget and reports object counts, logical bytes and skip reasons separately.
The sccache service is not restarted; its in-memory size can lag disk eviction
until entries are replaced or the service restarts.

Run `canaryd clean` to apply these checks manually.

View or change the retention with:

```sh
canaryd config build-retention       # show the effective retention (default: 24h)
canaryd config build-retention 48h   # save a 48-hour retention
canaryd config build-retention 24h   # use the default duration again
```

The setting accepts whole hours from `1h` to `87600h` and is saved per user in
`~/Library/Application Support/canaryd/build-cleanup-retention`. Both scheduled
and manual cleanup read it at the start of each round; no restart is required.
An invalid or unreadable configuration stops that round with an error.

<!-- readme-video:start -->
<p align="center">
  <a href="./hyperframes-src/canaryd-core-stories/output/publish/stories/stale-build-cleanup/stale-build-cleanup.mp4?raw=1" data-poster="./hyperframes-src/canaryd-core-stories/output/publish/frames/stale-build-cleanup.png">
    <img src="./hyperframes-src/canaryd-core-stories/output/publish/stories/stale-build-cleanup/stale-build-cleanup.gif" width="860" alt="Canaryd validates stale Xcode DerivedData and Cargo target directories before removing only reproducible build output">
  </a>
  <br>
  <sub>The build-cleanup story plays inline. Click it for the MP4. It follows the maintained cleanup specification.</sub>
</p>
<!-- readme-video:end -->

## Status at a glance

Run `canaryd status` to see current temperatures, CleanClip health, recent
recovery events, pending app hangs, idle high-memory apps, idle Simulators,
idle Codex screen-control helpers, and leftover Playwright Chrome for Testing.

![Example Canaryd status output](./docs/assets/canaryd-status.svg)

> The screenshot contains representative values. Process names, temperatures,
> and events come from the current Mac.

## Install

### Install with an AI agent

Give this prompt to Codex, Claude Code, Cursor, or another coding agent:

```text
Read https://raw.githubusercontent.com/ThaddeusJiang/canaryd/main/SKILL.md and follow its instructions to install or update Canaryd on this Mac.
```

### Requirements

- macOS on Apple Silicon or Intel
- Xcode Command Line Tools for the native notification helper
- `macmon 0.8.0` for exact CPU and GPU temperatures on Apple Silicon

The GitHub Release executable includes Erlang and Elixir. A source or Hex
installation needs Elixir 1.15 or later.

Install the system tools:

```sh
xcode-select -p >/dev/null || xcode-select --install

if [ "$(uname -m)" = "arm64" ]; then
  brew install macmon
  brew pin macmon
  macmon --version
fi
```

On Apple Silicon, the last command must print `macmon 0.8.0`. Canaryd rejects
another version until its JSON schema is verified. Intel Macs do not provide
exact CPU and GPU sensor temperatures.

### Install the latest stable release

```sh
curl -fsSL https://github.com/ThaddeusJiang/canaryd/releases/latest/download/install.sh | bash
```

The installer selects the Mac architecture, verifies SHA-256, and installs
`canaryd` in `~/.local/bin`. It adds that directory to the current shell profile
when necessary.
Reinstalling the same executable leaves the installed file unchanged.

Restart the shell, or run the `source` command printed by the installer, then:

```sh
canaryd start
canaryd status
```

`canaryd start` enables two background tasks, including after login:

| Agent | Schedule | Work |
| --- | ---: | --- |
| Full health check | Every 5 minutes | Check temperature, high-CPU processes, the system, GUI apps, idle memory, Simulators, Codex screen-control helpers, and CleanClip |
| Build cleanup | Daily at 04:00 | Remove stale Xcode/Cargo outputs, including backup and temporary targets, orphaned Bazel output bases, and stale shared repository entries |

Use `canaryd stop` to stop both tasks until you run `canaryd start` again.
Status, history, help, and manual checks do not start background tasks. You do
not need to manage plist files. Run `canaryd start` after upgrading to refresh
the background tasks and notification helper.
Repeating `canaryd start` keeps unchanged, loaded tasks in place. Only missing
or changed tasks are loaded or refreshed. This avoids unnecessary macOS
background activity notifications; macOS may still notify after an actual
executable or task configuration update.

<details>
<summary><strong>Manual archive, source, and Hex installation</strong></summary>

### Install a downloaded archive

Open the [latest GitHub Release](https://github.com/ThaddeusJiang/canaryd/releases/latest)
and download `checksums-sha256.txt` plus the archive for the Mac:

| Mac | Archive |
| --- | --- |
| Apple Silicon | `canaryd-aarch64-apple-darwin.tar.gz` |
| Intel | `canaryd-x86_64-apple-darwin.tar.gz` |

Verify and install it:

```sh
cd "$HOME/Downloads"

if [ "$(uname -m)" = "arm64" ]; then
  archive="canaryd-aarch64-apple-darwin.tar.gz"
else
  archive="canaryd-x86_64-apple-darwin.tar.gz"
fi

grep " $archive\$" checksums-sha256.txt | shasum -a 256 -c -
tar -xzf "$archive"
mkdir -p "$HOME/.local/bin"

# Run this only after the checksum succeeds. Current releases are not notarized.
xattr -d com.apple.quarantine canaryd 2>/dev/null || true
install -m 755 canaryd "$HOME/.local/bin/canaryd"
```

Current releases use ad hoc code signing and are not Apple-notarized. The
checksum verifies the downloaded release asset; it does not provide an Apple
Developer ID identity.

### Install the current source

```sh
git clone https://github.com/ThaddeusJiang/canaryd.git
cd canaryd
mix deps.get
mix escript.build
mix escript.install --force ./canaryd
```

### Install the published Hex release

```sh
mix escript.install hex canaryd 0.4.6
```

Add the relevant install directory to `PATH` if the shell cannot find
`canaryd`:

```sh
export PATH="$HOME/.local/bin:$HOME/.mix/escripts:$PATH"
```

</details>

## Commands

| Command | Purpose |
| --- | --- |
| `canaryd status` | Show the current health snapshot and recent events |
| `canaryd check` | Run one full health check now |
| `canaryd thermal-check` | Run one thermal and high-CPU process check now |
| `canaryd clean` | Clean stale Xcode/Cargo outputs, orphaned Bazel output bases, and stale shared repository entries now |
| `canaryd config build-retention [48h]` | Show or save the build cleanup retention; defaults to 24h |
| `canaryd reclaim [--dry-run]` | Reclaim confirmed quiet Codex helpers, or preview PIDs and protection reasons without acting |
| `canaryd history [target]` | Show events for `cleanclip`, `system`, `thermal`, `memory`, `simulators`, `codex`, `playwright`, `builds`, or `apps` |
| `canaryd start` | Start background monitoring, including after login |
| `canaryd stop` | Stop background monitoring until the next `start`; keep saved state and logs |
| `canaryd --version` | Show the installed version without changing the launchd agents |

`install` and `uninstall` remain compatibility aliases for `start` and `stop`.

Examples:

```sh
canaryd check
canaryd history thermal
canaryd history memory
canaryd history simulators
canaryd history codex
canaryd history playwright
canaryd history builds
canaryd history apps
```

## Safety model

Canaryd confirms abnormal behavior before changing another process.

| Signal | Confirmation | Response |
| --- | --- | --- |
| CPU or GPU heat | Three temperature samples; two rounds for the same actionable leader | Warn first, then offer Close or Restart |
| GUI app hang | macOS Not Responding state in two consecutive rounds | Restart a supported third-party app in the background |
| Idle high memory | 30 minutes of user inactivity and three low-CPU, 1 GB+ rounds | Request a graceful app close |
| Idle Simulator | 15 minutes since the latest known device or foreground activity | Shut down the exact booted UDID on the next check |
| Idle Codex tool hosts | 30 observed minutes of unchanged cumulative CPU time and no children; connected legacy adapters also require user inactivity | Send `SIGTERM` to the revalidated exact PID |
| Leftover Playwright Chrome for Testing | Not frontmost, no Playwright runner, and three unchanged process observations | Send `SIGTERM` to the revalidated exact PID |
| Stale build output | Complete tree inactive for the configured retention (default 24h) and related tools idle | Remove a validated DerivedData or Cargo target directory |
| CleanClip process missing | Process check | Start it in the background |
| CleanClip function missing | Reversible real-history probe | Restart quietly; notify only when recovery is blocked |
| System pressure | Three consecutive full checks | Send one system-degraded notification |

The shared safety rules are:

- Battery temperature never substitutes for CPU or GPU temperature.
- CPU use identifies suspects; it does not prove exact heat attribution.
- Apple apps, system daemons, active apps, and unsafe helper processes are
  protected from general automatic actions.
- A newer user clipboard write always wins over CleanClip probe restoration.
- Idle-memory recovery never uses `SIGKILL`.
- Simulator recovery never runs `erase`, `delete`, `reset`, or `shutdown all`.
- Whole-Mac keyboard and pointer activity does not reset Simulator inactivity.
- Active current-user `xcodebuild` and `xctest` processes block Simulator
  shutdown.
- Codex helper cleanup matches only fixed Computer Use service,
  `SkyComputerUseClient computer-history mcp`, `node_repl`,
  legacy `unified-computer-use`, bundled `@oai/cua-repl`, and `cua-driver mcp`
  signatures. It protects continuous
  Computer History capture (`event-stream`), other client modes,
  `cua-driver serve`, unrelated Node.js processes, and the Codex app server.
- Codex helper cleanup preserves processes with children, including initialized
  REPL kernels. CPU activity, identity changes, and scan gaps reset confirmation.
  It revalidates the exact PID, sends only `SIGTERM`, and never stores command lines.
- Playwright Chrome cleanup matches only the main Chrome for Testing binary
  under `Library/Caches/ms-playwright`. It protects Google Chrome, Dia,
  Clicknow, helpers, crashpad, the frontmost app, and active Playwright runners.
  It does not wait for whole-Mac user idle.
- Playwright Chrome cleanup revalidates an exact PID, sends only `SIGTERM`, and
  never stores the command line used for classification.
- Xcode/Cargo cleanup pauses while related tools are active and removes only
  validated, reproducible directories whose complete trees have reached the
  configured retention (default 24h), including Cargo targets in Codex workspace
  backups and directly under `/private/tmp`. Targets containing running
  executables are retained.
- Bazel output-base cleanup requires a missing local workspace, no active server, and an
  exclusive native lock on that output base. Starting clients or unavailable
  process inspection block deletion.
- Shared Bazel repository entries require the configured retention without modification,
  no active Bazel client or server, and all known output-base locks. Extracted
  repositories additionally use the native GC lock; install caches remain.
- Workspace backup containers, archives, unmerged changes, development data,
  and test evidence outside validated build directories are retained.
- Build cleanup never removes Xcode Archives, DeviceSupport, SDKs, UserData,
  Simulator data, Cargo registry or git caches, installed binaries, or source.
- App restart, prompt, and close actions use one-hour cooldowns.
- Automatic termination can still interrupt background work or expose an
  unsaved-changes prompt.

For exact behavior, see the maintained feature specifications:

- [Unresponsive app recovery](./docs/specs/001-unresponsive-app-recovery.md)
- [CleanClip functional health probe](./docs/specs/002-cleanclip-health-probe.md)
- [Thermal process monitor](./docs/specs/003-thermal-process-monitor.md)
- [Idle memory process monitor](./docs/specs/007-idle-memory-process-monitor.md)
- [Idle Simulator shutdown](./docs/specs/008-idle-simulator-shutdown.md)
- [Stale build cleanup](./docs/specs/009-stale-build-cleanup.md)
- [Idle Codex process cleanup](./docs/specs/010-idle-codex-process-cleanup.md)
- [Leftover Playwright Chrome cleanup](./docs/specs/011-idle-playwright-chrome-cleanup.md)

## Local data

Canaryd stores runtime data only on the Mac:

```text
~/Library/Application Support/canaryd/
├── state.dets
├── events.dets
├── stdout.log
└── stderr.log
```

`state.dets` contains current confirmation and cooldown state. `events.dets`
contains the local recovery timeline, including build-cleanup actions. The log
files contain launchd output. Canaryd does not store document content or process
command-line arguments in its event history.

## Stop or remove Canaryd

Stop background monitoring:

```sh
canaryd stop
```

This removes the scheduled tasks and notification helper, keeping the executable,
saved state, events, and logs. It stays stopped across logins; `canaryd start`
restores background monitoring. Manual `check`, `thermal-check`, and `clean`
commands still run once when requested.

To remove the executable, saved state, and logs too (default installation path):

```sh
rm "$HOME/.local/bin/canaryd"
rm -r "$HOME/Library/Application Support/canaryd"
```

## Development

```sh
git clone https://github.com/ThaddeusJiang/canaryd.git
cd canaryd
mix deps.get
mix test
mix escript.build
```

Build the native executable with Zig 0.16.0:

```sh
mise install zig@0.16.0
BURRITO_TARGET=macos_arm64 MIX_ENV=prod mise exec zig@0.16.0 -- mix release --overwrite
./burrito_out/canaryd_macos_arm64 --version
```

The project uses Elixir/OTP, DETS storage, launchd, and a small Swift
notification helper.

Node.js 24 or later is required only when regenerating the HyperFrames story
media under `hyperframes-src/`.

## License

[MIT](./LICENSE)
