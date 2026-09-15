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
- Publish `rc.N` tags as GitHub prereleases.
- Keep the existing escript build for Hex users.
- Publish the matching package and documentation to Hex from the same release workflow.

## Behavior

1. Start the CLI with the arguments from the Burrito wrapper.
2. Use the Burrito wrapper path when Canaryd writes launchd agent files.
3. Keep the escript path behavior for an escript installation.
4. Run `canaryd --version` without installing or loading the launchd agent.
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
15. Accept stable tags and `rc.N` tags that match the Mix project version.
16. Mark each `rc.N` GitHub Release as a prerelease.
17. Resolve every user-specific directory from the runtime user environment.
18. Do not include the release build user's home directory in runtime paths.
19. Publish the GitHub Release and Hex package from the same version tag.
20. Read the Hex publish key only from the `HEX_API_KEY` GitHub Actions secret.
21. Preserve the installed executable when its bytes match the verified download
    and it is executable. Compare bytes, not version strings, so different builds
    of the same version can still be installed.
22. Repeated `canaryd start` calls preserve unchanged, loaded launchd jobs and
    their plist files. Load missing jobs and refresh only changed configurations.
23. If unloading a changed job fails, report the failure and preserve its old
    plist. Retry a failed load without reloading successful sibling jobs.

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
- Follow-up tests: preserve inode and modification time on an identical
  reinstall; replace changed bytes with the same version string; repair missing
  execute permission.

### BDD-04 Publish a release candidate

Given:
- An `rc.N` tag matches the Mix project version.

When:
- The release workflow publishes the tag.

Then:
- GitHub marks the release as a prerelease.
- GitHub does not replace the latest stable release.

Test Plan:
- Lowest useful level: workflow contract test.
- Follow-up test: inspect the published GitHub Release.

### BDD-05 Use the runtime user's directories

Given:
- A release executable was built by a different macOS user.
- The executable runs with the current user's `HOME` environment variable.

When:
- Canaryd installs its notification helper and launchd agent.
- Canaryd reads or writes its state and CleanClip history paths.

Then:
- Canaryd uses directories under the runtime user's home directory.
- Canaryd does not use the release build user's home directory.

Test Plan:
- Lowest useful level: unit tests for all user-specific path functions.
- First failing test: change `HOME` after module compilation and resolve every user-specific path.
- Follow-up test: inspect the packaged executable for a build-user application support path.

### BDD-06 Publish the matching Hex package

Given:
- A release tag matches the Mix project version.
- GitHub Actions can read the `HEX_API_KEY` secret.

When:
- The release workflow publishes the tag.

Then:
- GitHub contains the release assets for the tag.
- Hex contains the package and documentation for the same version.

Test Plan:
- Lowest useful level: workflow contract test.
- First failing test: require one Hex publish step with a step-scoped secret.
- Follow-up test: inspect the public Hex package after the workflow completes.

### BDD-07 Repeat background setup without re-registering unchanged jobs

Given:
- Both current background jobs are loaded with their expected configuration.

When:
- The user runs `canaryd start` again.

Then:
- No current job is unloaded or registered again.
- Existing plist contents, inode, and modification time remain unchanged.
- A missing job is loaded without rewriting its unchanged plist.
- A changed job is unloaded and reloaded without disturbing its sibling.
- The obsolete thermal job is removed independently.
- Failed unloads and loads are reported and can be retried.

Test Plan:
- Lowest useful level: setup integration tests with real temporary files and an
  injected launchctl runner, plus a local macOS check of repeated setup.
- First failing tests: repeat setup and reinstall identical release bytes;
  observe unwanted launchctl calls and changed file modification times.
- Actual executable or configuration updates may still trigger macOS background
  activity notifications. Suppressing system notifications is outside this change.

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
| BDD-04 | passed | `Canaryd.ReleaseConfigTest` | The release workflow adds the GitHub prerelease flag for `rc.N` tags. |
| BDD-05 | passed | `Canaryd.RuntimePathsTest`; ARM64 executable run with an isolated `HOME`; extracted payload inspection | Reported by the `v0.3.0-rc.1` user test. |
| BDD-06 | passed | [Release workflow](https://github.com/ThaddeusJiang/canaryd/actions/runs/30779692926), [Hex package](https://hex.pm/packages/canaryd/0.3.0), and [HexDocs](https://hexdocs.pm/canaryd/0.3.0/) | The workflow published `0.3.0` to GitHub and Hex. |
| BDD-07 | passed | `Canaryd.SetupLifecycleTest`; two consecutive starts using the new source on macOS 26.6.2 | Both live BTM records and plist, executable, and notification-helper metadata stayed unchanged. Real updates can still trigger system notifications. |
