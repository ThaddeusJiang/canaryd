# 010 Idle Codex Process Cleanup

## Purpose

Reclaim quiet Codex tool hosts even while the user works elsewhere on the Mac.
Process age alone and instantaneous CPU percentage are not inactivity signals.
The 24-hour build retention setting does not apply to processes.

## Scope

Supported current-user command signatures:

- Codex Computer Use `SkyComputerUseService`.
- Codex `SkyComputerUseClient computer-history mcp`.
- ChatGPT/Codex `cua_node/bin/node_repl`.
- The legacy `unified-computer-use` Node launcher and the bundled
  `@oai/cua-repl/bin/cua-repl.mjs` launcher. The bundled Node executable and
  launcher must belong to the same application installation.
- Per-task `cua-driver mcp`.

The application, renderers, app server, GPU/network services, `cua-driver serve`,
ordinary Node processes, artifact servers, continuous Computer History capture,
and unknown commands are excluded. Canaryd does not infer task ownership or read
prompts, conversation logs, environment variables, or browser content.

## Reclamation Policy

Every full health check scans helpers regardless of keyboard/pointer activity.

1. Any helper with a direct child process is protected. This includes REPLs
   hosting execution kernels, even if their CPU usage is zero. Child inspection
   includes other users' processes. A CUA wrapper with a REPL child is retained;
   the empty child can qualify independently, and the bundled wrapper normally
   exits when that child exits.
2. Childless `node_repl` and CUA launchers can be observed while the user is
   active. Parent PID 1 alone is not proof of abandonment on macOS.
3. Other connected MCP/service helpers additionally require at least 30 minutes
   of whole-Mac inactivity. They lack a reliable independent activity signal.
4. Require at least 30 **observed** minutes with unchanged cumulative CPU time,
   parent PID, kind, PID, and start time. Require at least three observations,
   counted no more frequently than once every five minutes. With the default
   five-minute schedule, reclamation first qualifies on the seventh scan.
5. CPU changes, new children, parent changes, PID reuse, unavailable/malformed
   scans, disappearance, backwards clocks, and gaps over ten minutes reset the
   window. Sleep and daemon downtime do not count as observed inactivity.
6. Immediately before acting, recheck policy eligibility and scan again. The
   exact identity, parent, cumulative CPU time, and absence of children must
   still match. Send `SIGTERM` to one positive PID only and briefly await exit.
   Never send `SIGKILL`, `pkill`, or a process-group signal.
7. A failed, skipped, or completed action starts a fresh observation window if
   the process is found again.

A childless REPL indicates that no execution kernel is currently attached, not
that its owning task has ended. CPU time has the precision exposed by macOS
`ps` (hundredths of a second). Samples cannot prove absence of all activity or
eliminate the race between revalidation and signaling. Closing a persistent
MCP connection may require reconnecting or reopening its task for subsequent
tool use. Initialized sessions remain protected until their children exit;
this policy does not promise automatic reclamation of every unused session.

## Collection and Persistence

`Canaryd.CodexProcesses` reads PID, parent PID, UID, start time, cumulative CPU
time, and command using `ps`, with a fixed C locale and no `sudo`. Command text
is discarded after classification. Commands are bounded to five seconds and
4 MiB of output. A snapshot permits at most 16,384 rows and 250 supported
candidates; malformed or duplicate-PID rows fail the whole scan closed.

`IdleCodexProcessMonitor.observations` is keyed by fixed kind, PID, and start
time. Each entry stores a bounded process snapshot, observation count,
`quiet_since`, `last_seen`, and `counted_at` in Unix milliseconds. Legacy entries
without time/activity fields restart confirmation. No atoms are created from
process metadata.

The existing locked DETS store serializes scheduled and manual checks. Events
use target `codex_processes`, keeping bounded identity, count, and action result;
command lines and task content are never persisted. Existing batched success
and failure notifications apply.

## User Interface

- `canaryd check`: includes reclamation in the normal health-check schedule.
- `canaryd reclaim --dry-run`: shows supported PIDs, observation progress, and
  protection reasons. It neither signals processes nor changes observations or
  event history. It does not prepare notification helpers.
- `canaryd reclaim`: runs only this monitor, sharing its safety window, store,
  and lock with scheduled checks. It does not force cleanup or bypass timing.
- `canaryd status`: shows pending helpers from the last recorded check.
- `canaryd history codex`: shows detection, termination, skip, and failure events.

No new dependency, scheduled job, or user setting is required.

## BDD Scenarios

### BDD-01 Reclaim quiet unused tool hosts during normal Mac use

Given a childless supported REPL, when cumulative CPU time and identity stay
unchanged across checks for 30 minutes, then Canaryd revalidates and sends
`SIGTERM` even if the user is typing in another application.

### BDD-02 Preserve sessions with work or uncertain activity

Given a REPL with an execution kernel, a changed CPU counter or parent, a reused
PID, a protected shared service, or an unknown command, then it is not stopped.
The same protection is checked immediately before signaling. Connected legacy
adapters also remain protected while the user is active.

### BDD-03 Require real observation time

Given repeated manual invocations, a legacy saved sequence, a backwards clock,
an unavailable scan, or a gap longer than ten minutes, then Canaryd cannot reuse
that history to bypass a fresh 30-minute observation window.

### BDD-04 Preview without changing the outcome of later checks

Given a confirmed candidate and a protected helper, when running a dry run, then
the candidate is shown as `would stop`, the helper's reason is displayed, and no
signals, observation updates, events, or notifications occur.

## Cross-Spec Links

- [005 Time Unit Convention](./005-time-unit-convention.md)
- [007 Idle Memory Process Monitor](./007-idle-memory-process-monitor.md)
- [008 Idle Simulator Shutdown](./008-idle-simulator-shutdown.md)

## Acceptance Record

| Scenario | Status | Evidence |
| --- | --- | --- |
| BDD-01 | passed | Monitor/checker tests; owned live REPL received SIGTERM after an accelerated observation window; owned bundled CUA wrapper exited with its reclaimed REPL child |
| BDD-02 | passed | Scanner and termination tests cover children, other users, shared services, changed CPU/parent/identity, and revalidation failures |
| BDD-03 | passed | Monitor tests cover real elapsed time, rapid calls, unavailable scans, old state, missing processes, and clock/scan gaps |
| BDD-04 | passed | Isolated DETS integration tests verify no signals or state/event changes; live CLI preview lists observation progress and protection reasons |

The live signal checks used newly created test helpers only. Observation time
was accelerated; a 30-minute production soak and post-reclamation reconnection
of an existing Codex task have not been verified.
