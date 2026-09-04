# Canaryd project instructions

## Local signoff

The `main` branch requires the `signoff` commit status. Run validation appropriate to the change on the exact revision that will be reviewed, push that revision, and sign off only after confirming that the tested revision is the current remote PR head. Code changes normally require `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`, and `mix test`; documentation-only changes require at least `git diff --check` plus any directly relevant checks.

Use the stable Basecamp GitHub CLI extension. If `gh signoff` is unavailable, install the pinned release with `gh extension install basecamp/gh-signoff --pin v0.4.1`. Do not use `-f` to bypass the clean and pushed-revision checks.

For each PR head, resolve the locally tested commit and compare it with GitHub before signing:

```bash
pr="<PR number or URL>"
tested_sha="<SHA of the locally tested revision>"
pr_head="$(gh pr view "$pr" --json headRefOid --jq .headRefOid)"
test "$tested_sha" = "$pr_head"
gh signoff --commit "$tested_sha"
gh signoff status --commit "$tested_sha"
```

For Git, `git rev-parse HEAD` resolves the current commit. For Jujutsu, set `revision` to the tested revision and run `jj log -r "$revision" --no-graph -T 'commit_id ++ "\n"'`. A new PR-head commit requires a new signoff; never treat a status on an earlier commit as approval of the current head. If validation fails or is incomplete, do not publish a successful signoff.
