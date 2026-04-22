#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=./ci-lib.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/ci-lib.sh"

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
Usage: ./scripts/build-deb-package.sh --source <portable.tar.gz> --metadata <build-metadata.env> --output-dir <dir> [--pkgrel <n>] [--pkgver <version>]

Options:
  --source PATH      Portable release archive produced by codex-linux-build/build.sh --package
  --metadata PATH    build-metadata.env generated alongside the portable archive
  --output-dir PATH  Directory that will receive .deb and checksum files
  --pkgrel N         Debian package revision (default: 1)
  --pkgver VERSION   Override the Debian package version
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

    for cmd in dpkg-deb realpath sha256sum tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'Missing required commands: %s\n' "${missing[*]}" >&2
        exit 1
    fi
}

derive_package_version() {
    local release_label="$1"
    local pkgver="${PACKAGE_VERSION:-${RELEASE_VERSION:-${UPSTREAM_VERSION:-${release_label#v}}}}"

    pkgver="${pkgver//_/.}"
    pkgver="${pkgver// /.}"

    if [ -z "$pkgver" ]; then
        printf 'Unable to derive Debian package version.\n' >&2
        exit 1
    fi

    printf '%s\n' "$pkgver"
}

write_control_file() {
    local control_path="$1"
    local package_version="$2"

    cat >"$control_path" <<EOF
Package: codex-desktop-native
Version: ${package_version}-${PKGREL}
Section: utils
Priority: optional
Architecture: amd64
Maintainer: mazix
Depends: libc6, libasound2, libatk-bridge2.0-0, libatk1.0-0, libcups2, libdbus-1-3, libdrm2, libgbm1, libglib2.0-0, libgtk-3-0, libnspr4, libnss3, libx11-6, libx11-xcb1, libxcb-dri3-0, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxkbcommon0, libxrandr2, xdg-utils
Provides: codex-desktop
Conflicts: codex-desktop
Replaces: codex-desktop
Description: Prebuilt native Linux package for OpenAI Codex Desktop
 Bundles the patched Codex Desktop runtime, Electron, launcher, icons,
 and desktop entry for Debian and Ubuntu systems.
EOF
}

main() {
    local release_label=""
    local package_version=""
    local release_asset_name=""
    local extract_dir=""
    local release_root=""
    local package_root=""
    local control_dir=""
    local icon_size=""

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

    require_file "$SOURCE_ARCHIVE"
    require_file "$METADATA_FILE"

    # shellcheck disable=SC1090
    source "$METADATA_FILE"

    release_label="${RELEASE_TAG:-${RELEASE_VERSION:-${UPSTREAM_VERSION:-}}}"
    release_label="${release_label#refs/tags/}"
    if [ -z "$release_label" ]; then
        printf 'RELEASE_TAG/UPSTREAM_VERSION is missing in metadata.\n' >&2
        exit 1
    fi

    package_version="$(derive_package_version "$release_label")"
    release_asset_name="$(deb_release_filename "$package_version")"

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-deb-package.XXXXXX")"
    extract_dir="$WORK_DIR/extract"
    package_root="$WORK_DIR/package-root"
    control_dir="$package_root/DEBIAN"

    mkdir -p "$extract_dir" "$control_dir" "$package_root/opt/codex-desktop"
    tar -xzf "$SOURCE_ARCHIVE" -C "$extract_dir"

    release_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [ -z "$release_root" ] || [ ! -d "$release_root" ]; then
        printf 'Portable archive did not extract into a top-level directory.\n' >&2
        exit 1
    fi

    cp -a --no-preserve=ownership "$release_root/." "$package_root/opt/codex-desktop/"
    install -Dm755 "$PROJECT_ROOT/packaging/arch/codex-desktop-wrapper.sh" "$package_root/usr/bin/codex-desktop"
    install -Dm644 "$PROJECT_ROOT/packaging/arch/codex-desktop.desktop" "$package_root/usr/share/applications/codex-desktop.desktop"
    install -Dm644 "$package_root/opt/codex-desktop/codex-icon.png" "$package_root/usr/share/pixmaps/codex-desktop.png"

    for icon_size in 16 24 32 48 64 128 256 512; do
        if [ -f "$package_root/opt/codex-desktop/icons/hicolor/${icon_size}x${icon_size}/apps/codex-desktop.png" ]; then
            install -Dm644 \
                "$package_root/opt/codex-desktop/icons/hicolor/${icon_size}x${icon_size}/apps/codex-desktop.png" \
                "$package_root/usr/share/icons/hicolor/${icon_size}x${icon_size}/apps/codex-desktop.png"
        fi
    done

    if [ -f "$release_root/LICENSE" ]; then
        install -Dm644 "$release_root/LICENSE" "$package_root/usr/share/doc/codex-desktop-native/copyright"
    fi

    if [ -f "$release_root/README.md" ]; then
        install -Dm644 "$release_root/README.md" "$package_root/usr/share/doc/codex-desktop-native/README.md"
    fi

    write_control_file "$control_dir/control" "$package_version"
    chmod 0755 "$package_root/DEBIAN"

    dpkg-deb --root-owner-group --build "$package_root" "$OUTPUT_DIR/$release_asset_name"
    (
        cd "$OUTPUT_DIR"
        sha256sum "$release_asset_name" > "$release_asset_name.sha256"
    )

    printf 'Debian package artifacts written to %s\n' "$OUTPUT_DIR"
}

main "$@"
