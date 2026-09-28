# 014 Configurable Decision Thresholds

All values that determine when Canaryd warns, confirms a condition, or takes
an automatic action are per-user settings with defaults matching the existing
behavior. `canaryd config` lists every key and effective value. `canaryd config
<key> <value>` changes one setting without starting a check or an action.

The keys cover:

- System load, CPU/GPU chip temperature, memory-free warning, and hot-process
  CPU filtering, plus system warning confirmation and cooldown.
- Thermal alert and prompt confirmation/cooldowns.
- High-memory RSS and CPU criteria, swap used/growth criteria, detached-build
  observations, and each monitor's spacing, maximum gap, confirmation count,
  and notification cooldown.
- Quiet Codex helper observation time and confirmation. This remains
  observation-only; changing a threshold does not enable termination.
- Simulator inactivity, Playwright browser confirmation, unresponsive-app
  confirmation and restart cooldown, and CleanClip probe/restart policy.
- Storage-pressure cleanup cooldown. The separate `storage-threshold` and
  `build-retention` settings continue to govern free-space entry and validated
  build-output age.
- Full-check cadence and the local daily cleanup time.

`canaryd config --path` prints the editable per-user file at
`~/Library/Application Support/canaryd/config.conf`. It accepts `key=value`
lines, blank lines, and full-line `#` comments. CLI `config` setters update
this same file and preserve other entries and comments. Entries override the
legacy per-key files in `thresholds/`, `storage-threshold`, and
`build-cleanup-retention`; a key missing from the shared file still uses its
legacy file, then its default. Legacy files are left untouched. Unknown or
duplicate keys, invalid values, oversized files, symlinks, and unreadable
files fail closed; Canaryd never silently falls back to defaults. Policy
values are validated as a group so confirmation spacing cannot
exceed its maximum gap and the check cadence cannot exceed any maximum gap.
The check interval must divide 60 minutes because launchd uses clock slots.
Frequent checks retain observations but only advance confirmations after the
configured minimum spacing; they do not reset or inflate confirmation counts.
Changing schedule settings requires `canaryd start` to rewrite the launchd
agents; other settings take effect on the next check.

## Keys and defaults

`G` and `M` mean GiB and MiB. Duration values use whole minutes (`m`) or
hours (`h`). All keys below can be read/set using `canaryd config <key> [value]`
and edited as `key=value` in the same file. Ranges are inclusive; schedule and
spacing relationships above must also hold.

| Key | Default and range |
| --- | --- |
| `storage-threshold` | default 20G, range 1G..1024G |
| `build-retention` | default 24h, range 1h..87600h |
+| `build-process-alert-cooldown` | default 60m, range 1m..1440m |
| `build-process-confirmations` | default 3, range 1..20 |
| `build-process-max-gap` | default 10m, range 1m..120m |
| `build-process-min-spacing` | default 5m, range 1m..60m |
| `check-interval` | default 5m, range 1m..60m |
| `cleanclip-failure-confirmations` | default 3, range 1..20 |
| `cleanclip-probe-interval` | default 30m, range 1m..1440m |
| `cleanclip-restart-cooldown` | default 60m, range 15m..1440m |
| `cleanup-time` | default 04:00, local clock 00:00..23:59 |
| `codex-confirmations` | default 3, range 1..20 |
| `codex-max-gap` | default 10m, range 1m..120m |
| `codex-min-idle` | default 30m, range 1m..1440m |
| `codex-min-spacing` | default 5m, range 1m..60m |
| `memory-alert-cooldown` | default 60m, range 1m..1440m |
| `memory-confirmations` | default 3, range 1..20 |
| `memory-cpu` | default 1.0%, range 0.0%..100.0% |
| `memory-max-gap` | default 10m, range 1m..120m |
| `memory-min-spacing` | default 5m, range 1m..60m |
| `memory-rss` | default 1024M, range 128M..65536M |
| `playwright-confirmations` | default 3, range 2..20 |
| `simulator-min-idle` | default 15m, range 5m..1440m |
| `storage-cleanup-cooldown` | default 60m, range 15m..1440m |
| `swap-alert-cooldown` | default 60m, range 1m..1440m |
| `swap-confirmations` | default 3, range 1..20 |
| `swap-max-gap` | default 10m, range 1m..120m |
| `swap-min-growth` | default 512M, range 64M..1048576M |
| `swap-min-spacing` | default 5m, range 1m..60m |
| `swap-min-used` | default 2048M, range 128M..1048576M |
| `system-chip-temperature` | default 70.0C, range 40.0C..110.0C |
| `system-failure-confirmations` | default 3, range 1..20 |
| `system-hot-process-cpu` | default 20.0%, range 1.0%..400.0% |
| `system-load-factor` | default 0.8, range 0.1..4.0 |
| `system-memory-free` | default 10%, range 1%..50% |
| `system-restart-cooldown` | default 60m, range 1m..1440m |
| `thermal-alert-cooldown` | default 15m, range 1m..1440m |
| `thermal-confirmations` | default 2, range 2..20 |
| `thermal-prompt-cooldown` | default 60m, range 15m..1440m |
| `unresponsive-confirmations` | default 2, range 2..20 |
| `unresponsive-restart-cooldown` | default 60m, range 15m..1440m |

These settings do not relax fixed safety boundaries: protected apps and active
work remain protected; an exact Simulator UDID or Playwright PID is revalidated
before termination; high-memory, swap, detached-build, and Codex-host findings
never authorize automatic process termination; storage pressure only requests
the existing guarded build cleanup. Internal parser size limits, command
timeouts, and per-round work budgets are implementation safety caps, not
decision thresholds.
