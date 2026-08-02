#!/usr/bin/env bash

set -euo pipefail

release_url="${CANARYD_RELEASE_URL:-https://github.com/ThaddeusJiang/canaryd/releases/latest/download}"
install_dir="${CANARYD_INSTALL_DIR:-$HOME/.local/bin}"
architecture="${CANARYD_ARCH:-$(uname -m)}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Canaryd supports macOS only." >&2
  exit 1
fi

case "$architecture" in
  arm64)
    asset="canaryd-aarch64-apple-darwin.tar.gz"
    ;;
  x86_64)
    asset="canaryd-x86_64-apple-darwin.tar.gz"
    ;;
  *)
    echo "Unsupported Mac architecture: $architecture" >&2
    exit 1
    ;;
esac

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/canaryd-install.XXXXXX")"

cleanup() {
  rm -rf -- "$temporary_dir"
}

trap cleanup EXIT

archive_path="$temporary_dir/$asset"
checksums_path="$temporary_dir/checksums-sha256.txt"

echo "Downloading $asset"
curl -fsSL --output "$archive_path" "${release_url%/}/$asset"
curl -fsSL --output "$checksums_path" "${release_url%/}/checksums-sha256.txt"

expected_checksum="$(awk -v asset="$asset" '$2 == asset {print $1}' "$checksums_path")"

if ! printf '%s\n' "$expected_checksum" | grep -Eq '^[0-9a-fA-F]{64}$'; then
  echo "The release checksum file does not contain one valid checksum for $asset." >&2
  exit 1
fi

actual_checksum="$(shasum -a 256 "$archive_path" | awk '{print $1}')"

if [ "$(printf '%s' "$actual_checksum" | tr '[:upper:]' '[:lower:]')" != \
  "$(printf '%s' "$expected_checksum" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "SHA-256 verification failed for $asset." >&2
  exit 1
fi

echo "Verified SHA-256 for $asset"
tar -xzf "$archive_path" -C "$temporary_dir"

executable_path="$temporary_dir/canaryd"

if [ ! -f "$executable_path" ]; then
  echo "The release archive does not contain canaryd." >&2
  exit 1
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.quarantine "$executable_path" 2>/dev/null || true
fi

mkdir -p "$install_dir"
install -m 755 "$executable_path" "$install_dir/canaryd"

profile_path=""

if [ "${CANARYD_SKIP_PROFILE_UPDATE:-0}" != "1" ]; then
  case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
      shell_path="${SHELL:-}"

      case "${shell_path##*/}" in
        zsh) profile_path="${CANARYD_PROFILE_PATH:-$HOME/.zshrc}" ;;
        bash) profile_path="${CANARYD_PROFILE_PATH:-$HOME/.bash_profile}" ;;
      esac

      if [ -n "$profile_path" ]; then
        path_line="export PATH=\"$install_dir:\$PATH\""
        touch "$profile_path"

        if ! grep -Fqx "$path_line" "$profile_path"; then
          printf '\n%s\n' "$path_line" >> "$profile_path"
        fi
      fi
      ;;
  esac
fi

version_output="$("$install_dir/canaryd" --version)"
echo "Installed $version_output to $install_dir/canaryd"

case ":$PATH:" in
  *":$install_dir:"*)
    echo "Run: canaryd status"
    ;;
  *)
    if [ -n "$profile_path" ]; then
      echo "Restart the shell or run: source $profile_path"
    else
      echo "Add this directory to PATH: $install_dir"
    fi

    echo "Then run: canaryd status"
    ;;
esac
