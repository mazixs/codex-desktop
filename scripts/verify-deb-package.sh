#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ci-lib.sh
source "$SCRIPT_DIR/ci-lib.sh"

PACKAGE_FILE=""
LAUNCHER="${LAUNCHER:-codex-desktop}"

usage() {
    cat <<'EOF'
Usage: ./scripts/verify-deb-package.sh --package <file.deb> [--launcher <cmd>]

Options:
  --package FILE      Debian package file to validate and install
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
        ci_fail "Debian package is missing required entry: $entry"
    fi
}

install_package() {
    if [ "${EUID}" -eq 0 ]; then
        dpkg -i "$PACKAGE_FILE"
        return
    fi

    require_command sudo
    sudo dpkg -i "$PACKAGE_FILE"
}

run_smoke_test() {
    local smoke_log="/tmp/codex-desktop-smoke.log"
    local launch_rc=0

    mkdir -p "$HOME/.cache" "$HOME/.config" "$HOME/.local/share"
    timeout 25s xvfb-run -a "$LAUNCHER" >"$smoke_log" 2>&1 || launch_rc=$?
    if [ "$launch_rc" -ne 0 ] && [ "$launch_rc" -ne 124 ]; then
        cat "$smoke_log"
        exit 1
    fi

    if grep -Eq "Electron runtime not found|Build output not found|Codex CLI not found" "$smoke_log"; then
        cat "$smoke_log"
        exit 1
    fi
}

main() {
    local listing_file=""

    parse_args "$@"

    for cmd in dpkg dpkg-deb grep timeout xvfb-run; do
        require_command "$cmd"
    done

    if [ -z "$PACKAGE_FILE" ]; then
        usage >&2
        exit 1
    fi

    require_file "$PACKAGE_FILE"
    listing_file="$(mktemp "${TMPDIR:-/tmp}/codex-deb-package-list.XXXXXX")"
    dpkg-deb -c "$PACKAGE_FILE" | awk '{print $6}' >"$listing_file"

    assert_package_entry "$listing_file" "./opt/codex-desktop/start.sh"
    assert_package_entry "$listing_file" "./usr/bin/codex-desktop"
    assert_package_entry "$listing_file" "./usr/share/applications/codex-desktop.desktop"
    assert_package_entry "$listing_file" "./usr/share/pixmaps/codex-desktop.png"
    assert_package_entry "$listing_file" "./opt/codex-desktop/node_modules/electron/dist/electron"
    assert_package_entry "$listing_file" "./opt/codex-desktop/dist/.vite/build/bootstrap.js"

    install_package
    run_smoke_test

    rm -f "$listing_file"
    ci_log "Debian package contract verified: $PACKAGE_FILE"
}

main "$@"
