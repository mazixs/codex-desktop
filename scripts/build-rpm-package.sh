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
Usage: ./scripts/build-rpm-package.sh --source <portable.tar.gz> --metadata <build-metadata.env> --output-dir <dir> [--pkgrel <n>] [--pkgver <version>]

Options:
  --source PATH      Portable release archive produced by codex-linux-build/build.sh --package
  --metadata PATH    build-metadata.env generated alongside the portable archive
  --output-dir PATH  Directory that will receive .rpm and checksum files
  --pkgrel N         RPM package release number (default: 1)
  --pkgver VERSION   Override the RPM package version
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

    for cmd in rpmbuild realpath sha256sum tar; do
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

    pkgver="${pkgver//-/_}"
    pkgver="${pkgver// /_}"

    if [ -z "$pkgver" ]; then
        printf 'Unable to derive RPM package version.\n' >&2
        exit 1
    fi

    printf '%s\n' "$pkgver"
}

write_spec_file() {
    local spec_path="$1"
    local package_version="$2"

    cat >"$spec_path" <<EOF
Name: codex-desktop-native
Version: ${package_version}
Release: ${PKGREL}%{?dist}
Summary: Prebuilt native Linux package for OpenAI Codex Desktop
License: Apache-2.0
URL: https://github.com/mazixs/codex-desktop
Group: Applications/Productivity
Requires: alsa-lib, atk, cairo, dbus-libs, gdk-pixbuf2, glib2, gtk3, libX11, libXcomposite, libXcursor, libXdamage, libXext, libXfixes, libXi, libXrandr, libXrender, libXtst, libxcb, nss, pango, xdg-utils, libdrm, mesa-libgbm, libxkbcommon
Provides: codex-desktop
Conflicts: codex-desktop
Replaces: codex-desktop

%define debug_package %{nil}
%define __strip /bin/true
%define _build_id_links none

%description
Prebuilt native Linux package for OpenAI Codex Desktop.
Bundles the patched Codex Desktop runtime, Electron, launcher, icons,
and desktop entry for RPM-based systems (Fedora, RHEL, openSUSE).

%prep
# Nothing to do

%build
# Nothing to do

%install
# Pre-populated in BUILDROOT

%files
/opt/codex-desktop
/usr/bin/codex-desktop
/usr/share/applications/codex-desktop.desktop
/usr/share/pixmaps/codex-desktop.png
/usr/share/icons/hicolor/*/apps/codex-desktop.png
/usr/share/doc/codex-desktop-native/copyright
/usr/share/doc/codex-desktop-native/README.md
EOF
}

main() {
    local release_label=""
    local package_version=""
    local release_asset_name=""
    local extract_dir=""
    local release_root=""
    local buildroot=""
    local icon_size=""
    local rpm_built_path=""

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
    release_asset_name="$(rpm_release_filename "$package_version")"

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-rpm-package.XXXXXX")"
    extract_dir="$WORK_DIR/extract"
    # rpmbuild expects buildroot layout under BUILDROOT/<name>-<version>-<release>.<arch>
    buildroot="$WORK_DIR/BUILDROOT/codex-desktop-native-${package_version}-${PKGREL}.x86_64"

    mkdir -p "$extract_dir" "$buildroot/opt/codex-desktop"

    tar -xzf "$SOURCE_ARCHIVE" -C "$extract_dir"

    release_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    if [ -z "$release_root" ] || [ ! -d "$release_root" ]; then
        printf 'Portable archive did not extract into a top-level directory.\n' >&2
        exit 1
    fi

    cp -a --no-preserve=ownership "$release_root/." "$buildroot/opt/codex-desktop/"
    install -Dm755 "$PROJECT_ROOT/packaging/arch/codex-desktop-wrapper.sh" "$buildroot/usr/bin/codex-desktop"
    install -Dm644 "$PROJECT_ROOT/packaging/arch/codex-desktop.desktop" "$buildroot/usr/share/applications/codex-desktop.desktop"
    install -Dm644 "$buildroot/opt/codex-desktop/codex-icon.png" "$buildroot/usr/share/pixmaps/codex-desktop.png"

    for icon_size in 16 24 32 48 64 128 256 512; do
        if [ -f "$buildroot/opt/codex-desktop/icons/hicolor/${icon_size}x${icon_size}/apps/codex-desktop.png" ]; then
            install -Dm644 \
                "$buildroot/opt/codex-desktop/icons/hicolor/${icon_size}x${icon_size}/apps/codex-desktop.png" \
                "$buildroot/usr/share/icons/hicolor/${icon_size}x${icon_size}/apps/codex-desktop.png"
        fi
    done

    # RPM expects doc files to be placed in the buildroot manually if we just list them in %files
    mkdir -p "$buildroot/usr/share/doc/codex-desktop-native"
    if [ -f "$release_root/LICENSE" ]; then
        install -Dm644 "$release_root/LICENSE" "$buildroot/usr/share/doc/codex-desktop-native/copyright"
    fi

    if [ -f "$release_root/README.md" ]; then
        install -Dm644 "$release_root/README.md" "$buildroot/usr/share/doc/codex-desktop-native/README.md"
    fi

    write_spec_file "$WORK_DIR/codex-desktop.spec" "$package_version"

    # Run rpmbuild specifying the workspace topdir and rpmdir
    rpmbuild -bb \
        --define "_topdir $WORK_DIR" \
        --define "_rpmdir $WORK_DIR/RPMS" \
        "$WORK_DIR/codex-desktop.spec"

    rpm_built_path="$(find "$WORK_DIR/RPMS" -name '*.rpm' | head -n 1)"
    if [ -z "$rpm_built_path" ] || [ ! -f "$rpm_built_path" ]; then
        printf 'rpmbuild failed to produce an RPM package.\n' >&2
        exit 1
    fi

    cp "$rpm_built_path" "$OUTPUT_DIR/$release_asset_name"
    (
        cd "$OUTPUT_DIR"
        sha256sum "$release_asset_name" > "$release_asset_name.sha256"
    )

    printf 'RPM package artifacts written to %s\n' "$OUTPUT_DIR"
}

main "$@"
