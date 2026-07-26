# canaryd 🐤

> Canary in the coal mine for your Mac.

macOS health monitor that detects **overheating**, **apps marked Not Responding**, and **apps that are alive but silently dead** (process running, function stopped — e.g. CleanClip stops recording the clipboard). Self-heals via quiet restarts; only notifies the user when a target is confirmed `blocked`.

Pure Elixir/OTP, zero runtime dependencies, DETS storage, launchd-scheduled.

## Requirements

- macOS (Apple Silicon or Intel)
- Erlang/OTP + Elixir (any recent version; `~> 1.15`)

## Install

```sh
mix escript.install hex canaryd
```

That's it. The first time any `canaryd` command runs, it automatically registers a launchd agent that runs `canaryd check` every 5 minutes. If the agent is ever deleted, the next `canaryd` invocation re-creates it. No manual plist setup is ever needed.

## Usage

```sh
canaryd check              # run one check round (launchd does this automatically)
canaryd status             # current health snapshot + recent events
canaryd history [target]   # event timeline (cleanclip, system, or apps)
canaryd install            # force (re)install of the launchd agent (normally automatic)
canaryd uninstall          # remove the launchd agent
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
| L1 system | thermal throttling, load, memory pressure | `pmset -g therm`, `sysctl vm.loadavg`, `memory_pressure`; warns after 3 consecutive rounds |
| GUI response | supported process marked Not Responding | reads the WindowServer state used by Force Quit |
| Process | CleanClip process alive | `pgrep`; relaunches silently if dead |
| Function | CleanClip actually recording | synthetic probe: writes clipboard → verifies a new history file appears |

**Idle skip:** when keyboard/mouse has been idle > 30 min (`ioreg HIDIdleTime`), the CleanClip functional probe is skipped. The system check and GUI response scan still run.

**GUI app restart discipline:** a third-party, user-visible app must be marked Not Responding in two consecutive rounds. Canaryd then stops and opens the app in the background. Each app has a 1 h restart cooldown. Apple system apps, daemons, and helper processes are excluded unless listed below. Automatic termination can discard unsaved data.

**Cursor UI service:** `CursorUIViewService` is an explicitly supported Apple text-input service. After two consecutive Not Responding rounds, Canaryd sends a notification and shows a 120 s action dialog. The user can ignore, close, or restart the service. Close or Restart can force-stop the current instance. Restart waits for launchd or an XPC client to start a new PID. macOS can open the service again when needed. The prompt has a 1 h cooldown.

**CleanClip restart discipline:** probe failure → silent auto-restart (1 h cooldown, no user interruption); 3 consecutive failures within cooldown → status `blocked` + macOS notification. Recovery is logged automatically.

The Force Quit state has no public macOS API. Canaryd resolves the macOS interface at runtime. If a future macOS release removes it, this scan becomes unavailable and Canaryd does not stop any app.

## Data

All state lives in `~/Library/Application Support/canaryd/`:

- `state.dets` — latest state-machine snapshot per target
- `events.dets` — append-only event log (`hang_detected` / `closed` / `ignored` / `action_failed` / `restart_failed` / `probe_fail` / `restarted` / `blocked` / `recovered` / `system_warn` / `skipped_idle`)
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
