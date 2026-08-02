# Private Release Returned 404

## What happened

Canaryd `v0.3.0-rc.1` passed the authenticated release checks.
The public `curl` installation command returned HTTP 404 before it downloaded `install.sh`.
Users could not install the release without GitHub repository access.

## Root cause

The GitHub repository was private when the release was published.
GitHub returns HTTP 404 for anonymous requests to private repositories and their release assets.
The release checks used an authenticated GitHub CLI session.
They verified the assets but did not verify anonymous access.

## Fix applied

- Scanned all reachable Git commits with Gitleaks 8.30.1.
- Confirmed that the scan found no credentials.
- Confirmed that the repository had no forks.
- Changed the repository visibility from private to public.
- Repeated the installation with GitHub tokens removed from the environment.
- Verified the archive checksum and the installed `canaryd 0.3.0-rc.1` version.

## What we learned

- An uploaded release asset is not necessarily available to anonymous users.
- A public installation command needs an anonymous end-to-end test.
- Release validation must check repository visibility before it announces a public download URL.
- Authenticated GitHub CLI checks do not replace anonymous HTTP checks.
