# Build Home Baked Into Release

## What happened

The `v0.3.0-rc.1` executable failed when a user ran `canaryd status`.
Canaryd tried to create `/Users/runner/Library/Application Support/canaryd`.
macOS denied access because `/Users/runner` was the GitHub Actions build user home.

## Root cause

`Canaryd.Store` expanded its user data directory in a module attribute.
Elixir evaluated the module attribute during the release build.
The compiled BEAM file kept the absolute build user path.
The CleanClip history directory used the same compile-time pattern.

## Fix applied

- Added one runtime path module for user-specific directories.
- Read `HOME` when Canaryd resolves a user-specific path.
- Kept `System.user_home!/0` as a fallback when `HOME` is not set.
- Moved the Canaryd data, launchd agent, and CleanClip history paths to the runtime path module.
- Added a regression test that changes `HOME` after the application modules are compiled.
- Built both macOS executables and inspected an ARM64 payload extracted under an isolated home.

## What we learned

- A module attribute is part of the release artifact.
- A module attribute must not contain a build-user path for a portable executable.
- User-specific paths must be resolved when the executable runs.
- A release smoke test needs a runtime home that differs from the build home.
