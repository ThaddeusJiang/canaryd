# 010 Idle Codex Process Cleanup

Idle Codex screen-control helper cleanup specification.

## Purpose

Release CPU, memory, and screen-control resources held by forgotten Codex
Computer Use helpers without broadly terminating Codex, Node.js, or the
long-lived CUA Driver service.

## Scope

- In scope:
  - Current-user `SkyComputerUseService` processes installed under the Codex
    Computer Use app path.
  - ChatGPT or Codex `cua_node/bin/node_repl` processes.
  - ChatGPT or Codex Node processes running the installed
    `unified-computer-use` launcher.
  - Per-task `cua-driver mcp` processes.
  - User inactivity, consecutive confirmation, exact-PID revalidation, local
    status, event history, and batched notifications.
- Out of scope:
  - The Codex or ChatGPT application and app server.
  - `cua-driver serve`, ordinary Node.js processes, artifact servers, and
    unrelated MCP servers.
  - Inferring which Codex task owns a helper.
  - Inspecting or persisting prompts, documents, session IDs, or command-line
    arguments.
  - Forced termination with `SIGKILL`.

## Persistence

### Entities

- `IdleCodexProcessMonitor`
  - `observations`: A map keyed by fixed process kind, PID, and process start
    time with the latest bounded process snapshot and consecutive observation
    count.
- `CodexProcess`
  - `id`: A tuple of fixed process kind, PID, and process start time.
  - `kind`: One of the fixed supported process kinds.
  - `pid`: The current process identifier.
  - `ppid`: The observed parent process identifier.
  - `started_at`: The process start time reported by `ps`.
  - `name`: A fixed display name derived from the supported kind.
- `Event`
  - Use the existing DETS event store with target `codex_processes`.
  - Store only bounded identity fields, observation count, and action result.
  - Never store the command line used for classification.

### Lifecycle

- A supported process observed while the user is inactive creates or advances
  a pending observation.
- User activity, a missing process, an unavailable scan, or a changed process
  identity clears the incomplete sequence.
- Three consecutive observations produce one exact-PID termination action.
- The action rechecks user inactivity and process identity before sending
  `SIGTERM`.
- A stopped, replaced, failed, or skipped target requires a new
  three-observation sequence before another action.

### Constraints

- User inactivity must be at least 30 minutes.
- Confirmation requires three consecutive five-minute full check rounds.
- Only current-user processes with a fixed supported command signature are
  candidates.
- One scan accepts at most 250 candidates and fails closed above that bound.
- Actions use one positive PID and never use `pkill` or a name-only target.
- Termination never escalates from `SIGTERM` to `SIGKILL`.
- The monitor must not create atoms from process metadata.

## Relationships

- `Canaryd.Checker` runs the monitor during the five-minute full health check.
- `Canaryd.System.idle_duration/0` supplies whole-Mac keyboard and pointer
  inactivity.
- `Canaryd.CodexProcesses` classifies supported processes, discards command
  lines, revalidates identity, and requests termination.
- Thermal, idle-memory, Simulator, unresponsive-app, build-cleanup, and
  CleanClip policies remain independent.

## Behavior

1. While the user has been inactive for less than 30 minutes, skip process
   collection and clear incomplete observations.
2. Read PID, parent PID, UID, start time, and command through `ps` without
   `sudo`.
3. Keep only current-user processes matching one of the fixed supported
   signatures.
4. Discard command-line data after classification.
5. Require three consecutive eligible observations for the same kind, PID,
   and process start time.
6. Immediately before acting, recheck whole-Mac inactivity.
7. Re-scan and require the same PID and start time to retain the same supported
   identity.
8. Send `SIGTERM` to that exact PID and wait briefly for it to stop.
9. Never send `SIGKILL` and never use a broad process-name match.
10. Log detection, successful termination, skipped actions, and failed actions.
11. Batch successful or failed counts into at most one notification for each
    result class per check round.
12. Expose pending processes through `canaryd status` and events through
    `canaryd history codex`.

Whole-Mac inactivity and consecutive confirmation reduce false positives, but
they cannot prove that an unattended background Codex task will never need a
waiting helper again. The fixed allowlist and graceful exact-PID action bound
the impact of that limitation.

## BDD Scenarios

### BDD-01 Stop sustained idle screen-control helpers

Given:
- The user has been inactive for at least 30 minutes.
- A supported current-user helper remains present.

When:
- The same process kind, PID, and start time are observed for three consecutive
  full checks.

Then:
- Canaryd revalidates inactivity and the exact process identity.
- Canaryd sends `SIGTERM` to the exact PID.
- Canaryd logs the result and sends one batched notification for the round.

### BDD-02 Protect active, unrelated, and changed processes

Given:
- The user is active, or a process is `cua-driver serve`, an unrelated Node.js
  command, owned by another user, stopped, or replaced under the same PID.

When:
- Canaryd evaluates or revalidates the process list.

Then:
- Canaryd does not send a termination signal to that process.
- A later supported process starts a new confirmation sequence.

### BDD-03 Fail closed when process state is unavailable

Given:
- Process inspection fails or returns more than the bounded candidate count.

When:
- Canaryd runs a full check.

Then:
- Canaryd clears incomplete observations.
- Canaryd does not terminate any process from that scan.

## Cross-Spec Links

- [005 Time Unit Convention](./005-time-unit-convention.md)
- [007 Idle Memory Process Monitor](./007-idle-memory-process-monitor.md)
- [008 Idle Simulator Shutdown](./008-idle-simulator-shutdown.md)

## Open Questions

- Add a stronger per-task activity signal only when Codex exposes one with a
  stable, privacy-preserving identity.
