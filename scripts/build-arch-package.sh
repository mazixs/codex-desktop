#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE_ARCHIVE=""
METADATA_FILE=""
OUTPUT_DIR=""
PKGREL="${CODEX_PKGREL:-1}"
PACKAGE_VERSION=""
WORK_DIR=""

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'EOF'
Usage: ./scripts/build-arch-package.sh --source <portable.tar.gz> --metadata <build-metadata.env> --output-dir <dir> [--pkgrel <n>] [--pkgver <version>]

Options:
  --source PATH      Portable release archive produced by codex-linux-build/build.sh --package
  --metadata PATH    build-metadata.env generated alongside the portable archive
  --output-dir PATH  Directory that will receive .pkg.tar.zst and checksum files
  --pkgrel N         Pacman package release number (default: 1)
  --pkgver VERSION   Override the pacman package version
  --help             Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source)
                SOURCE_ARCHIVE="${2:-}"
                shift 2
                ;;
            --metadata)
                METADATA_FILE="${2:-}"
                shift 2
                ;;
            --output-dir)
                OUTPUT_DIR="${2:-}"
                shift 2
                ;;
            --pkgrel)
                PKGREL="${2:-}"
                shift 2
                ;;
            --pkgver)
                PACKAGE_VERSION="${2:-}"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

require_commands() {
    local missing=()
    local cmd

    for cmd in makepkg sha256sum realpath; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'Missing required commands: %s\n' "${missing[*]}" >&2
        exit 1
    fi

    if [ "${EUID}" -eq 0 ]; then
        printf 'Run this script as a regular user, not root.\n' >&2
        exit 1
    fi
}

derive_package_version() {
    local release_label="$1"
    local pkgver="${PACKAGE_VERSION:-${UPSTREAM_VERSION:-${release_label#v}}}"

    pkgver="${pkgver//-/_}"
    pkgver="${pkgver// /_}"

    if [ -z "$pkgver" ]; then
        printf 'Unable to derive pacman package version.\n' >&2
        exit 1
    fi

    printf '%s\n' "$pkgver"
}

main() {
    local source_basename=""
    local source_sha=""
    local release_label=""
    local package_version=""
    local release_asset_version=""
    local canonical_package_path=""
    local release_asset_name=""

    parse_args "$@"
    require_commands

    if [ -z "$SOURCE_ARCHIVE" ] || [ -z "$METADATA_FILE" ] || [ -z "$OUTPUT_DIR" ]; then
        usage >&2
        exit 1
    fi

    SOURCE_ARCHIVE="$(realpath "$SOURCE_ARCHIVE")"
    METADATA_FILE="$(realpath "$METADATA_FILE")"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"

    if [ ! -f "$SOURCE_ARCHIVE" ]; then
        printf 'Portable archive not found: %s\n' "$SOURCE_ARCHIVE" >&2
        exit 1
    fi

    if [ ! -f "$METADATA_FILE" ]; then
        printf 'Metadata file not found: %s\n' "$METADATA_FILE" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$METADATA_FILE"

    release_label="${RELEASE_TAG:-${UPSTREAM_VERSION:-}}"
    release_label="${release_label#refs/tags/}"
    if [ -z "$release_label" ]; then
        printf 'RELEASE_TAG/UPSTREAM_VERSION is missing in metadata.\n' >&2
        exit 1
    fi

    package_version="$(derive_package_version "$release_label")"
    source_basename="$(basename "$SOURCE_ARCHIVE")"
    source_sha="$(sha256sum "$SOURCE_ARCHIVE" | awk '{print $1}')"

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-arch-package.XXXXXX")"

    cp "$SOURCE_ARCHIVE" "$WORK_DIR/$source_basename"
    cp "$PROJECT_ROOT/packaging/arch/PKGBUILD" "$WORK_DIR/"
    cp "$PROJECT_ROOT/packaging/arch/codex-desktop.desktop" "$WORK_DIR/"
    cp "$PROJECT_ROOT/packaging/arch/codex-desktop-wrapper.sh" "$WORK_DIR/"

    (
        cd "$WORK_DIR"
        CODEX_PACKAGE_VERSION="$package_version" \
        CODEX_PKGREL="$PKGREL" \
        CODEX_RELEASE_LABEL="$release_label" \
        CODEX_SOURCE_ARCHIVE="$source_basename" \
        CODEX_SOURCE_SHA256="$source_sha" \
        CODEX_ELECTRON_VERSION="${ELECTRON_VERSION:-40.0.0}" \
        makepkg -f --nodeps --cleanbuild
    )

    canonical_package_path="$(find "$WORK_DIR" -maxdepth 1 -name '*.pkg.tar.zst' | head -n 1)"
    if [ -z "$canonical_package_path" ] || [ ! -f "$canonical_package_path" ]; then
        printf 'Built Arch package not found in %s\n' "$WORK_DIR" >&2
        exit 1
    fi

    release_asset_version="$package_version"
    release_asset_name="codex-desktop-native-${release_asset_version}-archlinux-x86_64.pkg.tar.zst"

    cp "$canonical_package_path" "$OUTPUT_DIR/$release_asset_name"
    (
        cd "$OUTPUT_DIR"
        sha256sum "$release_asset_name" > "$release_asset_name.sha256"
    )

    printf 'Arch package artifacts written to %s\n' "$OUTPUT_DIR"
}

main "$@"
