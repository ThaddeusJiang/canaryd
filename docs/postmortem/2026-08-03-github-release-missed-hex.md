# GitHub Release Missed Hex

## What happened

The `v0.3.0` GitHub Release was available.
Hex still showed `0.2.0` as the latest package.
Users could install the native executable, but Hex users could not install `0.3.0`.

## Root cause

The release workflow published only GitHub Release assets.
It did not run `mix hex.publish`.
The repository also had no `HEX_API_KEY` Actions secret.
The release checks did not verify both distribution services.

## Fix applied

- Added Hex publication to the existing release workflow.
- Used the same Git tag for the GitHub Release and Hex package.
- Limited the publish key to the Hex `api:write` permission.
- Scoped `HEX_API_KEY` to the Hex publish step.
- Added a workflow contract test.
- Added a public package check to the release acceptance plan.

## What we learned

- A release is complete only after every supported distribution service has the version.
- One workflow must use one version source for all release outputs.
- Release acceptance must check GitHub Releases and Hex.
