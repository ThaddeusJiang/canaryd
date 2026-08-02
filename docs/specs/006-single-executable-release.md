# 006 Single Executable Release

Single executable release specification.

## Purpose

Distribute Canaryd as one executable file for each supported macOS architecture.
Do not require the user to install Erlang or Elixir.

## Scope

- In scope:
  - Apple Silicon macOS executable.
  - Intel macOS executable.
  - The Erlang runtime and Canaryd resources inside each executable.
  - GitHub Release archives and SHA-256 checksums.
  - A release command that does not change local launchd state.
- Out of scope:
  - Linux and Windows executables.
  - Apple Developer ID signing and notarization.
  - Automatic updates.
  - The existing `macmon 0.8.0` system dependency.

## Distribution

- Build each executable with Burrito 1.6.0.
- Use one fixed Elixir, Erlang, and Zig version in the release workflow.
- Build `aarch64-apple-darwin` and `x86_64-apple-darwin` assets.
- Put one executable in each compressed release archive.
- Publish one SHA-256 checksum file for all archives.
- Keep the existing escript build for Hex users.

## Behavior

1. Start the CLI with the arguments from the Burrito wrapper.
2. Use the Burrito wrapper path when Canaryd writes launchd agent files.
3. Keep the escript path behavior for an escript installation.
4. Run `canaryd --version` without installing or loading launchd agents.
5. Include ERTS and all `priv` resources in each executable.
6. Build each release from an existing semantic version tag.
7. Require the tag version to match the Mix project version.
8. Check release configuration changes before publication.
9. Require explicit confirmation when configuration changes exist.
10. Upload both architecture archives and their checksums to GitHub Releases.
11. Upload an installation script that selects the correct Mac architecture.
12. Verify the selected archive before installing its executable.
13. Install the executable as `~/.local/bin/canaryd` by default.
14. Add the install directory to the current shell profile when necessary.

## BDD Scenarios

### BDD-01 Run without a system Erlang installation

Given:
- A user downloaded the executable for the Mac architecture.
- Erlang and Elixir are not present in the command search path.

When:
- The user runs `canaryd --version`.

Then:
- Canaryd prints its version.
- Canaryd does not install or load a launchd agent.
- The command exits successfully.

Test Plan:
- Lowest useful level: CLI unit test and packaged executable smoke test.
- First failing test: `--version` does not call the setup function.
- Follow-up test: run the packaged executable with an isolated `PATH`.

### BDD-02 Keep the installed executable path

Given:
- Canaryd runs from a Burrito executable.

When:
- Canaryd writes a launchd agent file.

Then:
- The agent command uses the Burrito wrapper path.
- The agent does not use a payload extraction path as its program path.

Test Plan:
- Lowest useful level: unit test for executable path selection.
- First failing test: the Burrito wrapper path has priority over the escript path.

### BDD-03 Install with one command

Given:
- A stable GitHub Release contains both architecture archives and checksums.

When:
- The user pipes the release `install.sh` asset to Bash.

Then:
- The script selects the archive for the current Mac architecture.
- The script stops when SHA-256 verification fails.
- The script installs the executable as `canaryd`.
- A new shell can find `canaryd` through `PATH`.

Test Plan:
- Lowest useful level: shell integration test with local release fixtures.
- First failing test: install a verified local archive into an isolated directory.
- Follow-up test: reject an archive with an invalid checksum.

## Security and Operations

- Every GitHub Action reference uses a full commit SHA.
- Every action SHA has a readable version comment.
- The workflow uses only the minimum `contents: write` permission.
- The release includes SHA-256 checksums.
- The first release is not notarized.
- macOS Gatekeeper can require a manual approval for the downloaded executable.

## Acceptance Record

| Scenario | Status | Evidence | Notes |
| --- | --- | --- | --- |
| BDD-01 | passed | `Canaryd.CLITest`; signed ARM64 archive smoke test; x86_64 Rosetta smoke test; isolated `PATH` | Gatekeeper is not part of the local smoke test. |
| BDD-02 | passed | `Canaryd.SetupTest` | Both installation formats stay supported. |
| BDD-03 | passed | `Canaryd.InstallScriptTest` | The test uses local release fixtures. |
