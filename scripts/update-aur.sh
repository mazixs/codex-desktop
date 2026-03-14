#!/usr/bin/env bash
set -euo pipefail

# Updates the AUR PKGBUILD with a new version and sha256, regenerates .SRCINFO,
# and optionally commits + pushes to the AUR git repository.
#
# Usage:
#   ./scripts/update-aur.sh --version 0.3.0 [--sha256 <hash>] [--aur-repo <path>] [--push]
#
# If --sha256 is omitted, the script downloads the archive to compute it.
# If --aur-repo is omitted, operates on packaging/aur/ in the project tree.
# If --push is given, commits and pushes to the AUR remote.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION=""
SHA256=""
AUR_REPO=""
DO_PUSH=false
PRODUCT_ID="codex-desktop-native"
GITHUB_REPO_URL="https://github.com/mazixs/codex-desktop"

usage() {
    cat <<'EOF'
Usage: ./scripts/update-aur.sh --version <ver> [--sha256 <hash>] [--aur-repo <path>] [--push]

Options:
  --version VERSION   Release version without 'v' prefix (e.g. 0.3.0)
  --sha256 HASH       SHA-256 of the portable archive. If omitted, downloaded and computed.
  --aur-repo PATH     Path to the cloned AUR git repository. Defaults to packaging/aur/.
  --push              Commit and push to the AUR remote after updating.
  --help              Show this help.
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --version)  VERSION="${2:-}";  shift 2 ;;
            --sha256)   SHA256="${2:-}";   shift 2 ;;
            --aur-repo) AUR_REPO="${2:-}"; shift 2 ;;
            --push)     DO_PUSH=true;      shift   ;;
            --help|-h)  usage; exit 0              ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

validate_inputs() {
    if [ -z "$VERSION" ]; then
        printf 'Error: --version is required.\n' >&2
        usage >&2
        exit 1
    fi

    if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        printf 'Error: version must match semver format (e.g. 0.3.0), got: %s\n' "$VERSION" >&2
        exit 1
    fi

    if [ -n "$SHA256" ]; then
        if ! printf '%s' "$SHA256" | grep -qE '^[a-fA-F0-9]{64}$'; then
            printf 'Error: sha256 must be a 64-character hex string, got: %s\n' "$SHA256" >&2
            exit 1
        fi
    fi
}

compute_sha256() {
    local version="$1"
    local archive_name="${PRODUCT_ID}-${version}-archlinux-x86_64.pkg.tar.zst"
    local download_url="${GITHUB_REPO_URL}/releases/download/v${version}/${archive_name}"
    local tmp_file=""

    printf 'Downloading %s to compute sha256...\n' "$download_url"
    tmp_file="$(mktemp)"
    trap 'rm -f "$tmp_file"' RETURN

    if ! curl -fSL --retry 3 -o "$tmp_file" "$download_url"; then
        printf 'Failed to download: %s\n' "$download_url" >&2
        exit 1
    fi

    sha256sum "$tmp_file" | awk '{print $1}'
}

update_pkgbuild() {
    local pkgbuild="$1"
    local version="$2"
    local sha256="$3"

    if [ ! -f "$pkgbuild" ]; then
        printf 'PKGBUILD not found: %s\n' "$pkgbuild" >&2
        exit 1
    fi

    sed -i "s/^pkgver=.*/pkgver=${version}/" "$pkgbuild"
    sed -i "s/^pkgrel=.*/pkgrel=1/" "$pkgbuild"

    # Replace the sha256 entry in the sha256sums array
    sed -i "s/'[a-fA-F0-9]\{64\}'/'${sha256}'/" "$pkgbuild"
    # Also handle PLACEHOLDER_SHA256
    sed -i "s/'PLACEHOLDER_SHA256'/'${sha256}'/" "$pkgbuild"

    printf 'Updated %s → pkgver=%s sha256=%s\n' "$pkgbuild" "$version" "$sha256"
}

generate_srcinfo() {
    local aur_dir="$1"

    if ! command -v makepkg >/dev/null 2>&1; then
        printf 'makepkg not found — cannot generate .SRCINFO. Run on Arch Linux.\n' >&2
        exit 1
    fi

    (
        cd "$aur_dir"
        makepkg --printsrcinfo > .SRCINFO
    )

    printf 'Generated %s/.SRCINFO\n' "$aur_dir"
}

commit_and_push() {
    local aur_dir="$1"
    local version="$2"

    (
        cd "$aur_dir"
        git add PKGBUILD .SRCINFO
        git commit -m "Update to ${version}"
        git push
    )

    printf 'Pushed %s v%s to AUR.\n' "$PRODUCT_ID" "$version"
}

main() {
    parse_args "$@"
    validate_inputs

    if [ -z "$AUR_REPO" ]; then
        AUR_REPO="$PROJECT_ROOT/packaging/aur"
    fi

    if [ -z "$SHA256" ]; then
        SHA256="$(compute_sha256 "$VERSION")"
    fi

    update_pkgbuild "$AUR_REPO/PKGBUILD" "$VERSION" "$SHA256"
    generate_srcinfo "$AUR_REPO"

    if [ "$DO_PUSH" = true ]; then
        commit_and_push "$AUR_REPO" "$VERSION"
    else
        printf 'Skipping push. Review changes in %s and push manually, or re-run with --push.\n' "$AUR_REPO"
    fi
}

main "$@"
