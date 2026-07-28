# canaryd 🐤

> Canary in the coal mine for your Mac.

macOS health monitor that detects **overheating**, **apps marked Not Responding**, and **apps that are alive but silently dead** (process running, function stopped — e.g. CleanClip stops recording the clipboard). Self-heals via quiet restarts; only notifies the user when a target is confirmed `blocked`.

Pure Elixir/OTP, DETS storage, launchd-scheduled. Exact Apple Silicon temperature
monitoring uses the pinned `macmon 0.8.0` sensor helper.

## Requirements

- macOS (Apple Silicon or Intel)
- Erlang/OTP + Elixir (any recent version; `~> 1.15`)
- `macmon 0.8.0` for exact CPU and GPU temperature on Apple Silicon
- Xcode Command Line Tools for the built-in notification helper

## Install

```sh
brew install macmon
brew pin macmon
mix escript.install hex canaryd
```

Verify that `macmon --version` prints `macmon 0.8.0`. Canaryd rejects other
versions until their JSON schema is verified.

The first time any `canaryd` command runs, it automatically registers two
launchd agents. One agent runs an exact temperature and thermal-process check
every minute. The other agent runs the full health check every 5 minutes. If an
agent is ever deleted, the next `canaryd` invocation re-creates it. No manual
plist setup is needed.

## Usage

```sh
canaryd check              # run one check round (launchd does this automatically)
canaryd thermal-check      # run one temperature and thermal-process check
canaryd status             # current health snapshot + recent events
canaryd history [target]   # event timeline (cleanclip, system, thermal, or apps)
canaryd install            # force (re)install of the launchd agents (normally automatic)
canaryd uninstall          # remove the launchd agents
```

### Example: `canaryd status`

```
cleanclip: ok | last_probe=ok failures=0 | last_restart=- | updated=2026-07-26 01:00:00
system: ok | last_probe=ok failures=0 | last_restart=- | updated=2026-07-26 01:00:00

recent events:
  2026-07-26 00:42:19  cleanclip  restarted
```

## How it works

Health model:

| Layer | What | Detection |
|---|---|---|
| L1 system | CPU/GPU temperature, thermal throttling, load, memory pressure | `macmon`, `pmset -g therm`, `sysctl vm.loadavg`, `memory_pressure`; warns after 3 consecutive rounds |
| Heat source | exact chip temperature and high-CPU process correlation | `macmon`, `ps`; asks after 2 consecutive rounds |
| GUI response | supported process marked Not Responding | reads the WindowServer state used by Force Quit |
| Process | CleanClip process alive | `pgrep`; relaunches silently if dead |
| Function | CleanClip actually recording | reversible clipboard probe → verifies a new history file appears |

**Idle skip:** when keyboard/mouse has been idle > 30 min (`ioreg HIDIdleTime`), the CleanClip functional probe is skipped. The system check and GUI response scan still run.

**Clipboard safety:** the CleanClip probe saves every current pasteboard item and data type. It restores that snapshot after the probe only when no newer pasteboard write occurred. A user copy during the probe always wins.

**GUI app restart discipline:** a third-party, user-visible app must be marked Not Responding in two consecutive rounds. Canaryd then stops and opens the app in the background. Each app has a 1 h restart cooldown. Apple system apps, daemons, and helper processes are excluded unless listed below. Automatic termination can discard unsaved data.

**Thermal process actions:** Canaryd uses `macmon 0.8.0` to read average CPU and GPU sensor temperature every minute. Each check keeps the highest value from a three-sample window. A CPU or GPU temperature of at least 70°C causes thermal pressure. Battery temperature stays a separate metric and never represents chip temperature. Canaryd sends a notification on the first thermal-pressure round. The warning stays in Notification Center until the user dismisses it. Canaryd applies a 15 min notification cooldown per leading process. During sustained thermal pressure, Canaryd lists up to five processes that use at least 20% CPU. CPU use is correlation evidence, not exact heat attribution. After the same third-party app leads two rounds, the notification offers Close and Restart. Dismiss or timeout means Ignore. Canaryd does not activate an app or take mouse focus. It never offers actions for Apple apps, system services, nested helper apps, or processes without a safe app bundle. Each app has a 1 h prompt cooldown.

**Cursor UI service:** `CursorUIViewService` is an explicitly supported Apple text-input service. After two consecutive Not Responding rounds, Canaryd sends a 120 s actionable notification. The notification offers Close and Restart. Dismiss or timeout means Ignore. Close or Restart can force-stop the current instance. Restart waits for launchd or an XPC client to start a new PID. macOS can open the service again when needed. The notification has a 1 h cooldown.

**CleanClip restart discipline:** probe failure → silent auto-restart (1 h cooldown, no user interruption); 3 consecutive failures within cooldown → status `blocked` + macOS notification. Recovery is logged automatically.

The Force Quit state has no public macOS API. Canaryd resolves the macOS interface at runtime. If a future macOS release removes it, this scan becomes unavailable and Canaryd does not stop any app.

## Data

All state lives in `~/Library/Application Support/canaryd/`:

- `state.dets` — latest state-machine snapshot per target
- `events.dets` — append-only event log for app, thermal, system, and probe actions
- `stdout.log` / `stderr.log` — launchd output

## Development

```sh
git clone https://github.com/ThaddeusJiang/canaryd
cd canaryd
mix test               # state machine unit tests
mix escript.build      # produces ./canaryd for local runs
```

## License

MIT
