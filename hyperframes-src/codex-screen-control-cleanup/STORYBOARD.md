---
mode: autonomous
message: "Canaryd safely monitors and cleans abandoned Codex screen-control helpers"
audience: developers
duration: 17.5
---

## Frame 01 — The process explosion

- status: outline
- src: `index.html#scene-problem`
- time: 0.0–4.0s
- role: hook
- motion: `ai-tracking-box` + `drift-hold`
- beat: “Too many screen-control processes.” A real Activity Monitor screenshot shows 12 visible `SkyComputerUseClient` rows. The full opening holds to 2.0s, then Canary-yellow tracking corners lock onto the repeated block.
- evidence: User-provided Activity Monitor screenshot plus the supported helper kinds and inactivity problem from spec 010. The count is explicitly limited to what is visible in this snapshot.

## Frame 02 — Observe, do not guess

- status: outline
- src: `index.html#scene-observe`
- time: 4.0–9.2s
- role: product action
- motion: `code-terminal-run`
- beat: A controlled terminal-shaped monitor view reports the 30-minute whole-Mac idle gate and the three-check policy.
- evidence: Default idle threshold and consecutive five-minute checks from spec 010.

## Frame 03 — Exact identity, safe signal

- status: outline
- src: `index.html#scene-clean`
- time: 9.2–13.7s
- role: safe result
- motion: `state-chip-rail` + `gloss-sweep`
- beat: Three observations lock, PID plus process start time is re-verified, then Canaryd sends SIGTERM only.
- evidence: Exact `{kind, pid, ps lstart}` identity, re-scan-before-action, and no SIGKILL from spec 010.

## Frame 04 — Brand promise

- status: outline
- src: `index.html#scene-close`
- time: 13.7–17.5s
- role: brand outro
- motion: `logo-brand-close`
- beat: “Clean up the abandoned. Leave active work alone.”
- evidence: Whole-Mac idle gate plus fail-closed termination policy.

## Rhythm

hold — scan — measured report — lock/clean — still brand close

## Audio

- 2.0s: restrained scan pulse.
- 5.1s and 7.1s: quiet observation pulses.
- 11.8s: clean confirmation chime, tailing into the brand close.
