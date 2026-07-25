# canaryd 🐤

> Canary in the coal mine for your Mac.

macOS health monitor that detects **overheating** and **apps that are alive but silently dead** (process running, function stopped — e.g. CleanClip stops recording the clipboard). Self-heals via quiet restarts; only notifies the user when a target is confirmed `blocked`.

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
canaryd history [target]   # event timeline (default: cleanclip)
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

Three-layer health model:

| Layer | What | Detection |
|---|---|---|
| L1 system | thermal throttling, load, memory pressure | `pmset -g therm`, `sysctl vm.loadavg`, `memory_pressure`; warns after 3 consecutive rounds |
| L2 process | CleanClip process alive | `pgrep`; relaunches silently if dead |
| L3 function | CleanClip actually recording | synthetic probe: writes clipboard → verifies a new history file appears |

**Idle skip:** when keyboard/mouse has been idle > 30 min (`ioreg HIDIdleTime`), only L1 is recorded — silence while the user is away is normal.

**Restart discipline:** probe failure → silent auto-restart (1 h cooldown, no user interruption); 3 consecutive failures within cooldown → status `blocked` + macOS notification (the only time the user is bothered). Recovery is logged automatically.

## Data

All state lives in `~/Library/Application Support/canaryd/`:

- `state.dets` — latest state-machine snapshot per target
- `events.dets` — append-only event log (`probe_fail` / `restarted` / `blocked` / `recovered` / `system_warn` / `skipped_idle`)
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
