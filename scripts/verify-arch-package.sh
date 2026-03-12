#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ci-lib.sh
source "$SCRIPT_DIR/ci-lib.sh"

PACKAGE_FILE=""
SMOKE_USER=""
LAUNCHER="${LAUNCHER:-codex-desktop}"

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-arch-package.sh --package <file.pkg.tar.zst> [--smoke-user <user>] [--launcher <cmd>]

Options:
  --package FILE      Arch package file to validate and install
  --smoke-user USER   Run the launch smoke test as USER
  --launcher CMD      Launcher command to execute after installation (default: codex-desktop)
  --help              Show this help
EOF
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --package)
                PACKAGE_FILE="${2:-}"
                shift 2
                ;;
            --smoke-user)
                SMOKE_USER="${2:-}"
                shift 2
                ;;
            --launcher)
                LAUNCHER="${2:-}"
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

assert_package_entry() {
    local listing_file="$1"
    local entry="$2"

    if ! grep -Fxq "$entry" "$listing_file"; then
        ci_fail "Arch package is missing required entry: $entry"
    fi
}

run_smoke_test() {
    local launch_command=""
    local smoke_log="/tmp/codex-desktop-smoke.log"

    launch_command="mkdir -p ~/.cache ~/.config ~/.local/share && launch_rc=0 && timeout 25s xvfb-run -a ${LAUNCHER} >${smoke_log} 2>&1 || launch_rc=\$?; if [ \"\$launch_rc\" -ne 0 ] && [ \"\$launch_rc\" -ne 124 ]; then cat ${smoke_log}; exit 1; fi; if grep -Eq \"Electron runtime not found|Build output not found|Codex CLI not found\" ${smoke_log}; then cat ${smoke_log}; exit 1; fi"

    if [ -n "$SMOKE_USER" ]; then
        runuser -u "$SMOKE_USER" -- bash -lc "$launch_command"
    else
        bash -lc "$launch_command"
    fi
}

main() {
    local listing_file=""

    parse_args "$@"

    for cmd in pacman tar timeout xvfb-run grep; do
        require_command "$cmd"
    done
    if [ -n "$SMOKE_USER" ]; then
        require_command runuser
    fi

    if [ -z "$PACKAGE_FILE" ]; then
        usage >&2
        exit 1
    fi

    require_file "$PACKAGE_FILE"
    listing_file="$(mktemp "${TMPDIR:-/tmp}/codex-arch-package-list.XXXXXX")"
    tar --zstd -tf "$PACKAGE_FILE" >"$listing_file"

    assert_package_entry "$listing_file" "usr/bin/codex-desktop"
    assert_package_entry "$listing_file" "usr/share/applications/codex-desktop.desktop"
    assert_package_entry "$listing_file" "usr/share/pixmaps/codex-desktop.png"
    assert_package_entry "$listing_file" "usr/share/icons/hicolor/256x256/apps/codex-desktop.png"
    assert_package_entry "$listing_file" "opt/codex-desktop/node_modules/electron/dist/electron"
    assert_package_entry "$listing_file" "opt/codex-desktop/dist/.vite/build/bootstrap.js"

    pacman -U --noconfirm "$PACKAGE_FILE"
    run_smoke_test

    rm -f "$listing_file"
    ci_log "Arch package contract verified: $PACKAGE_FILE"
}

main "$@"
