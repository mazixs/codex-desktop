#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ci-lib.sh
source "$SCRIPT_DIR/ci-lib.sh"

PORTABLE_DIR=""
ARCH_DIR=""
DEB_DIR=""

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-release-assets.sh --portable-dir <dir> --arch-dir <dir> --deb-dir <dir>

Options:
  --portable-dir DIR  Directory containing portable release assets
  --arch-dir DIR      Directory containing Arch release assets
  --deb-dir DIR       Directory containing Debian release assets
  --help              Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --portable-dir)
                PORTABLE_DIR="${2:-}"
                shift 2
                ;;
            --arch-dir)
                ARCH_DIR="${2:-}"
                shift 2
                ;;
            --deb-dir)
                DEB_DIR="${2:-}"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                ci_fail "Unknown option: $1"
                ;;
        esac
    done
}

main() {
    local portable_archive=""
    local arch_package=""
    local deb_package=""

    parse_args "$@"
    if [ -z "$PORTABLE_DIR" ] || [ -z "$ARCH_DIR" ] || [ -z "$DEB_DIR" ]; then
        usage >&2
        exit 1
    fi

    portable_archive="$(find_single_matching_file "$PORTABLE_DIR" "$(portable_release_glob)" "portable release archive")"
    arch_package="$(find_single_matching_file "$ARCH_DIR" "$(arch_release_glob)" "Arch release package")"
    deb_package="$(find_single_matching_file "$DEB_DIR" "$(deb_release_glob)" "Debian release package")"

    require_file "${portable_archive}.sha256"
    require_file "$PORTABLE_DIR/build-metadata.env"
    require_file "$PORTABLE_DIR/release-notes.md"
    require_file "${arch_package}.sha256"
    require_file "${deb_package}.sha256"

    assert_file_contains "$PORTABLE_DIR/release-notes.md" 'Arch Linux installer' "Release notes are missing the Arch Linux installer section"
    assert_file_contains "$PORTABLE_DIR/release-notes.md" 'Debian/Ubuntu installer' "Release notes are missing the Debian/Ubuntu installer section"
    assert_file_contains "$PORTABLE_DIR/release-notes.md" 'Portable Linux archive' "Release notes are missing the Portable Linux archive section"

    ci_log "Release asset contract verified"
    ci_log "Portable archive: $portable_archive"
    ci_log "Arch package: $arch_package"
    ci_log "Debian package: $deb_package"
}

main "$@"
