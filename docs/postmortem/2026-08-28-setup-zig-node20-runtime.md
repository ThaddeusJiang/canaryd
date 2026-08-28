# setup-zig Kept a Node.js 20 Runtime

## What happened

The release workflow emitted a warning because `mlugg/setup-zig` declared a
Node.js 20 action runtime. GitHub temporarily ran it with Node.js 24, so the
release still completed, but the workflow depended on a deprecated runtime.

## Root cause

The Node.js runtime of a JavaScript action is selected by the action's own
`action.yml`. Updating the repository's Node.js version cannot change that
runtime. The latest stable `mlugg/setup-zig` release still declared `node20`, so
there was no stable action version to upgrade to.

## Fix applied

- Removed the Node.js 20 action from the release workflow.
- Downloaded the fixed Zig 0.16.0 archive directly from the official Zig site.
- Selected the archive for the macOS runner architecture.
- Verified the official SHA-256 checksum before extraction.
- Declared Node.js 24 as the minimum for the HyperFrames source project.
- Added regression tests for both constraints.

## What we learned

- A project's Node.js version and a GitHub Action's bundled runtime are separate
  compatibility boundaries.
- When an action has no stable Node.js 24 release, a small checksum-pinned
  installer can be safer than silently accepting the deprecated runtime.
- Workflow dependencies must be audited from their action metadata, not inferred
  from the runner's fallback behavior.
