---
name: signoff
description: Validate a canaryd pull request head and publish or verify its required local signoff commit status with gh-signoff.
---

# Signoff

Use this skill when a canaryd pull request needs its required local `signoff` status.

1. Ensure the stable extension is available. If `gh signoff` is unavailable, install the pinned version with `gh extension install basecamp/gh-signoff --pin v0.4.1`.
2. Run validation appropriate to the exact revision to be signed. Code changes normally require `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`, and `mix test`. Documentation-only changes require at least a whitespace check and any directly relevant validation.
3. Push the tested revision, then resolve its full commit SHA. With Git, use `git rev-parse HEAD`. With Jujutsu, use `jj log -r <revision> --no-graph -T 'commit_id ++ "\n"'`.
4. Confirm that the tested SHA is the current remote PR head:

   ```bash
   pr="<PR number or URL>"
   tested_sha="<SHA of the tested revision>"
   pr_head="$(gh pr view "$pr" --json headRefOid --jq .headRefOid)"
   test "$tested_sha" = "$pr_head"
   ```

5. Publish the status and verify it:

   ```bash
   gh signoff --commit "$tested_sha"
   gh signoff status --commit "$tested_sha"
   gh pr view "$pr" --json statusCheckRollup
   ```

Do not use `-f`, sign failed or incomplete validation, or reuse a status from an earlier commit. Every new PR-head commit must be validated and signed again.
