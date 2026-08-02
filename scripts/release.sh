#!/usr/bin/env bash

set -euo pipefail

export MIX_ENV=prod

require_tag() {
  TAG="${TAG:-}"

  if ! printf '%s\n' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$'; then
    echo "Invalid release tag: $TAG" >&2
    exit 1
  fi
}

validate_config() {
  base_tag="$(git tag --merged HEAD --sort=-version:refname | grep -Fvx "$TAG" | head -n 1 || true)"

  if [ -n "$base_tag" ]; then
    base_ref="$base_tag"
  else
    base_ref="$(git rev-list --max-parents=0 HEAD | tail -n 1)"
  fi

  changed_files="$(git diff --name-only "${base_ref}..HEAD")"
  config_files="$(printf '%s\n' "$changed_files" | grep -E '(^|/)(\.env([^/]*)?|config|rel|deploy|deployment|ops|infra|k8s|kubernetes|helm|charts)(/|$)|(^|/)(Dockerfile|Containerfile|docker-compose[^/]*\.ya?ml|compose[^/]*\.ya?ml|Caddyfile|fly\.toml|render\.yaml|railway\.json|vercel\.json|netlify\.toml|mise\.toml|\.tool-versions|mix\.exs|mix\.lock)$|^\.github/workflows/' || true)"

  config_diff="$(git diff --unified=0 "${base_ref}..HEAD" -- '.env*' config rel deploy deployment ops infra k8s kubernetes helm charts .github/workflows mix.exs mix.lock || true)"
  added_env="$(printf '%s\n' "$config_diff" | awk '/^\+[^+]/{print}' | grep -Eo '[A-Z][A-Z0-9_]{2,}' | sort -u || true)"
  removed_env="$(printf '%s\n' "$config_diff" | awk '/^-[^-]/{print}' | grep -Eo '[A-Z][A-Z0-9_]{2,}' | sort -u || true)"

  summary="$(printf '%s\n' \
    '## Release configuration gate' \
    '' \
    "- Base: ${base_ref}" \
    "- Target: ${TAG}" \
    "- Config files: ${config_files:-none}" \
    "- Added env keys: ${added_env:-none}" \
    "- Removed env keys: ${removed_env:-none}")"

  printf '%s\n' "$summary"

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"
  fi

  if { [ -n "$config_files" ] || [ -n "$added_env" ] || [ -n "$removed_env" ]; } &&
    [ "${CONFIG_CHANGES_CONFIRMED:-false}" != "true" ]; then
    echo "Release configuration changes need explicit confirmation." >&2
    exit 1
  fi
}

validate_release() {
  require_tag

  tag_commit="$(git rev-parse "refs/tags/${TAG}^{commit}")"
  head_commit="$(git rev-parse HEAD)"
  test "$tag_commit" = "$head_commit"

  project_version="$(sed -nE 's/^[[:space:]]*version: "([^"]+)",/\1/p' mix.exs)"
  test -n "$project_version"
  test "$TAG" = "v${project_version}"

  validate_config
}

build_release() {
  require_tag
  mix deps.get
  mix release --overwrite

  arm64_binary="burrito_out/canaryd_macos_arm64"
  x86_64_binary="burrito_out/canaryd_macos_x86_64"

  file "$arm64_binary" | grep -F "Mach-O 64-bit executable arm64"
  file "$x86_64_binary" | grep -F "Mach-O 64-bit executable x86_64"

  chmod 755 "$arm64_binary" "$x86_64_binary"
  codesign --force --sign - "$arm64_binary"
  codesign --force --sign - "$x86_64_binary"
  codesign --verify --strict "$arm64_binary"
  codesign --verify --strict "$x86_64_binary"

  env -i HOME="$HOME" PATH=/usr/bin:/bin "$arm64_binary" --version |
    grep -Fx "canaryd ${TAG#v}"

  mkdir -p dist/arm64 dist/x86_64
  cp "$arm64_binary" dist/arm64/canaryd
  cp "$x86_64_binary" dist/x86_64/canaryd

  COPYFILE_DISABLE=1 tar -C dist/arm64 -czf dist/canaryd-aarch64-apple-darwin.tar.gz canaryd
  COPYFILE_DISABLE=1 tar -C dist/x86_64 -czf dist/canaryd-x86_64-apple-darwin.tar.gz canaryd

  test "$(tar -tzf dist/canaryd-aarch64-apple-darwin.tar.gz)" = "canaryd"
  test "$(tar -tzf dist/canaryd-x86_64-apple-darwin.tar.gz)" = "canaryd"

  (
    cd dist
    shasum -a 256 canaryd-*.tar.gz > checksums-sha256.txt
  )
}

create_github_release() {
  gh release create "$TAG" \
    dist/canaryd-aarch64-apple-darwin.tar.gz \
    dist/canaryd-x86_64-apple-darwin.tar.gz \
    dist/checksums-sha256.txt \
    scripts/install.sh \
    "$@" \
    --verify-tag \
    --generate-notes \
    --notes "The macOS executables are ad hoc signed. They are not notarized. Verify checksums before installation."
}

publish_release() {
  require_tag

  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" \
      dist/canaryd-aarch64-apple-darwin.tar.gz \
      dist/canaryd-x86_64-apple-darwin.tar.gz \
      dist/checksums-sha256.txt \
      scripts/install.sh \
      --clobber
  elif printf '%s\n' "$TAG" | grep -Eq -- '-rc\.[1-9][0-9]*$'; then
    create_github_release --prerelease
  else
    create_github_release
  fi
}

case "${1:-}" in
  validate) validate_release ;;
  build) build_release ;;
  publish) publish_release ;;
  *)
    echo "Usage: scripts/release.sh <validate|build|publish>" >&2
    exit 1
    ;;
esac
