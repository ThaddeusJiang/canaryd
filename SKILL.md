---
name: canaryd
description: Install or update Canaryd from its official GitHub Release on macOS, configure its required tools, register its launchd agents, and verify the result. Use when a user asks to install, update, set up, or repair Canaryd.
---

# Install or update Canaryd

Install Canaryd on the current Mac. Keep the process non-interactive when
possible.

## Safety rules

- Stop if the operating system is not macOS.
- Install only the latest stable Canaryd GitHub Release.
- Do not fall back to a GitHub branch, tag, or commit.
- Do not use `sudo`.
- Do not run `canaryd uninstall`.
- Do not delete Canaryd state, events, logs, or unrelated launchd agents.
- Stop and explain the problem when a required command fails.
- Ask the user to complete any macOS approval dialog.

## Inspect the Mac

Run:

```sh
sw_vers
uname -m
xcode-select -p
command -v brew
command -v canaryd || true
test -x "$HOME/.local/bin/canaryd" && echo "Canaryd executable is installed"
```

If Homebrew is not available, stop and ask the user to install it from
`https://brew.sh/`.

If the Xcode Command Line Tools are not available, run:

```sh
xcode-select --install
```

Ask the user to finish the macOS installer. Continue only after
`xcode-select -p` succeeds.

The GitHub Release executable includes Erlang and Elixir. Do not install them.

## Configure Apple Silicon temperature support

Run this section only when `uname -m` returns `arm64`.

Install `macmon` when it is missing:

```sh
command -v macmon >/dev/null || brew install macmon
macmon --version
```

Require the exact output `macmon 0.8.0`. Stop if the output differs. Pin the
verified formula:

```sh
brew pin macmon
```

On Intel, skip `macmon`. Report that exact CPU and GPU sensor temperatures are
not available.

## Install the official GitHub Release

Run the official installer:

```sh
curl -fsSL \
  https://github.com/ThaddeusJiang/canaryd/releases/latest/download/install.sh |
  bash
```

The installer selects the architecture, verifies the release SHA-256 checksum,
and installs `~/.local/bin/canaryd`. Use the same command for upgrades.

If `~/.local/bin` is not in `PATH`, add this line once to the profile for the
user's current interactive shell:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Do not change another shell profile.

## Register and verify Canaryd

Rewrite and load both launchd agents with the installed executable:

```sh
"$HOME/.local/bin/canaryd" --version
"$HOME/.local/bin/canaryd" install
"$HOME/.local/bin/canaryd" status
launchctl print "gui/$(id -u)/com.thaddeusjiang.canaryd"
launchctl print "gui/$(id -u)/com.thaddeusjiang.canaryd.thermal"
```

Confirm that both launchd commands succeed. Confirm that `canaryd status`
prints the current health snapshot.

Report:

- Whether this was an install or update.
- The installed Canaryd version.
- The Mac architecture and installed `macmon` version, when applicable.
- The result of `canaryd status`.
- Whether both launchd agents are loaded.
- Any user action that is still required.
- Tell the user to run this Skill again to upgrade to a newer stable release.

Show these common commands:

```sh
canaryd status
canaryd check
canaryd history thermal
canaryd history apps
```
