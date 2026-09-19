# 010 Codex Helper Observation and Reclamation Boundary

## Purpose

Identify quiet Codex tool hosts while preserving their owning sessions. Process
age, low CPU, and whole-Mac inactivity do not establish that a tool session ended.
Automatic Codex helper termination is disabled until ownership and safe client
recovery can be verified. Simulator and Playwright reclamation remain independent.

## Supported Processes

Recognize current-user fixed command signatures for:

- Codex Computer Use `SkyComputerUseService`.
- `SkyComputerUseClient computer-history mcp`.
- ChatGPT/Codex `cua_node/bin/node_repl`.
- Legacy `unified-computer-use` launchers and bundled `@oai/cua-repl/bin/cua-repl.mjs`.
  The bundled Node executable and launcher must belong to the same installation.
- Per-task `cua-driver mcp`.

Exclude the application, renderers, app server, GPU/network services, shared
`cua-driver serve`, ordinary Node, artifact servers, continuous history capture,
and unknown commands. Do not infer ownership from parent PID 1 or read task content.

## Observation Policy

1. Scan during normal Mac use. Helpers with direct children are protected, including
   initialized REPL kernels and CUA wrappers hosting a REPL. Child detection includes
   other users' processes.
2. Childless REPL/CUA hosts can be observed. Other adapters are reported with unknown
   session activity; whole-Mac idle does not make them disposable.
3. Report a quiet host after 30 minutes of unchanged cumulative CPU, parent, kind,
   PID, and start time. Count observations at least five minutes apart. The default
   schedule requires seven samples. No report sends a signal or closes a connection.
4. CPU/parent/identity changes, new children, failed scans, disappearing processes,
   backwards clocks, and gaps over ten minutes reset observations. Shorter gaps
   do not prove the machine stayed awake; quiet status is diagnostic only.
5. A quiet report logs `quiet_retained` with `session_activity_unknown`. A fresh
   observation window starts afterwards. No notification is sent for unchanged
   quiet helpers.

## Collection and Persistence

Read PID, parent, UID, start time, cumulative CPU, and command with `ps` in the C
locale. Discard command text after classification. Bound commands to five seconds
and 4 MiB; allow at most 16,384 rows and 250 supported candidates. Malformed or
repeated PID rows fail the whole scan closed. `ps` CPU precision is hundredths of
a second and cannot prove absence of all activity.

Use the existing locked DETS store and `idle_codex_processes` key. Observations use
Unix milliseconds and store bounded process identity, `quiet_since`, `last_seen`,
`counted_at`, and count. Legacy untimed observations restart confirmation. Events
contain no command lines, prompts, environment variables, or browser content.

## CLI

- `canaryd check`: observe helpers during the scheduled check.
- `canaryd reclaim --dry-run`: preview without changing observations or events.
- `canaryd reclaim`: record observations and explain why hosts remain retained.
  Despite the command name, automatic termination is disabled; the CLI says so.
- `canaryd status`: show pending observations.
- `canaryd history codex`: show observation and retained-host events, including
  historical termination events from older versions.

## Acceptance Evidence

Unit and isolated DETS tests cover classification, protection, observation timing,
legacy state, failure reset, and read-only previews. There is no Codex signaling
path in the scanner or checker.

On 2026-09-17, `scripts/verify_codex_reconnect.py` used the installed
`codex-cli 0.154.0-alpha.6.2` app server with temporary configuration and ephemeral
engine fixtures. It made no model requests and touched no existing user task.
Both the plain REPL and bundled CUA fixture connected and accepted `js_reset`.
After terminating only the newly spawned childless REPL, two subsequent calls
through the same session returned `Transport closed`. Reconnection failed, so the
previous proposed automatic empty-host termination was withdrawn.

On 2026-09-19, the same isolated fixtures reproduced both failures with
`codex-cli 0.155.0-alpha.9`: both subsequent calls returned `Transport closed`
for each transport. The newer client does not change the retention policy.

Reclamation requires a future reliable owner-release signal or verified transparent
client reconnection. A newer client version must be retested before changing policy.
