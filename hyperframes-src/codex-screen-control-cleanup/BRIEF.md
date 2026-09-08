---
workflow: general-video
flow: automation
storyboard: no
message: "Canaryd safely monitors and cleans abandoned Codex screen-control helpers"
destination: readme
aspect: 1920x1080
language: en
audience: developers
length: 17.5s
angle: controlled-product-demo
---

## Intent

A concise README demo for developers. Show the new release's core value first:
Canaryd watches Codex screen-control helpers, confirms abandonment over time,
re-verifies exact process identity, and sends SIGTERM without disturbing active
work.

## Assets

- `assets/brand/canaryd-logo.png` — official Canaryd logo used in the opening and close.
- `assets/screenshots/activity-monitor-skycomputeruseclient.jpg` — user-provided Activity Monitor evidence showing 12 visible `SkyComputerUseClient` processes in one snapshot.
- `assets/audio/scan-pulse.mp3` — bundled, reused short whoosh for observation events.
- `assets/audio/confirm-chime.mp3` — bundled, reused soft chime for verified cleanup.

## Customizations

- Controlled demo identifiers only; do not expose or terminate real screen-control processes.
- Open on the real Activity Monitor screenshot; state only the visible count and do not imply it is the system-wide total.
- One composition supplies MP4, poster, and review frames.

## Notes

- Product facts follow `docs/specs/010-idle-codex-process-cleanup.md`.
- Keep the opening visually unchanged until 2.0 seconds.
- No narration and no BGM. Audio is meaningful-event SFX only.
- Always label representative process data as `CONTROLLED DEMO`.

## Audio Mode

- primary: sfx
- music: no
- sfx: meaningful-events-only
- captions: not-required
- mix: level-match + final-listen
